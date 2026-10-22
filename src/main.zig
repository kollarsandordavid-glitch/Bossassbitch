const std = @import("std");
const build_options = @import("build_options");
const core = @import("engine_core");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_dir: []const u8 = "./settings";
    var role: []const u8 = build_options.default_role;
    var mode: []const u8 = "daemon";
    var input_path: []const u8 = "";
    var output_path: []const u8 = "";
    var run_once = false;

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--config-dir=")) {
            config_dir = arg["--config-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--role=")) {
            role = arg["--role=".len..];
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            mode = arg["--mode=".len..];
        } else if (std.mem.startsWith(u8, arg, "--input=")) {
            input_path = arg["--input=".len..];
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output_path = arg["--output=".len..];
        } else if (std.mem.eql(u8, arg, "--once")) {
            run_once = true;
        }
    }

    var rt = try core.runtime.lifecycle.RuntimeLifecycle.init(allocator, config_dir, false);
    defer rt.deinit();

    var crawler = try core.crawl.crawl_coordinator.CrawlCoordinator.init(allocator, rt.config.crawler);
    defer crawler.deinit();

    var stream = try core.ingestion.stream_engine.StreamEngine.init(allocator, rt.config.ingestion);
    defer stream.deinit();

    var embedder = try core.models.embedding_service.EmbeddingService.init(allocator, rt.config.model);
    defer embedder.deinit();

    var trainer = try core.training.training_coordinator.TrainingCoordinator.init(
        allocator,
        rt.config.training,
        rt.config.model,
    );
    defer trainer.deinit();

    if (std.mem.eql(u8, mode, "modal-train-step")) {
        const metrics = try trainer.runTrainingIterationAndCheckpoint();
        if (output_path.len > 0) {
            var f = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
            defer f.close();
            try f.writer().print(
                "{{\"status\":\"completed\",\"role\":\"{s}\",\"global_step\":{d},\"stage\":{d},\"joint_loss\":{d:.5},\"learned_temperature\":{d:.4}}}",
                .{ role, metrics.global_step, metrics.curriculum_stage, metrics.joint_loss, metrics.learned_temperature },
            );
        }
        return;
    }

    if (std.mem.eql(u8, mode, "modal-embed-batch")) {
        const emb = try embedder.embedQueryText(if (input_path.len > 0) input_path else "modal gpu batch item");
        if (output_path.len > 0) {
            var f = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
            defer f.close();
            const hex = std.fmt.bytesToHex(emb.quantized_binary.packed_bytes, .lower);
            try f.writer().print(
                "{{\"status\":\"completed\",\"model_version\":{d},\"primary_dim\":4096,\"retained_dim\":256,\"packed_binary_hex\":\"{s}\",\"original_norm\":{d:.4}}}",
                .{ emb.model_version, hex, emb.original_norm },
            );
        }
        return;
    }

    var vec_idx = try core.index.vector_index.DistributedVectorIndex.init(
        allocator,
        rt.config.vector_index,
        rt.config.model.model_version,
    );
    defer vec_idx.deinit();

    var sparse_idx = core.retrieval.sparse_index.SparseInvertedIndex.init(allocator);
    defer sparse_idx.deinit();

    var doc_store = try core.storage.document_store.DocumentStore.init(allocator, rt.config.storage.document_store_path);
    defer doc_store.deinit();

    var neural_reranker = core.retrieval.reranker.NeuralReranker.init(.{
        .max_rerank_candidates = rt.config.ranking.rerank_top_k,
        .enable_flash_attention_2 = rt.config.ranking.enable_flash_attention_2,
        .enable_fp8_quantization = rt.config.ranking.enable_fp8_reranker,
    });

    var entity_cls = try core.models.entity_classifier.EntityClassifier.init(
        allocator,
        rt.config.storage.entity_eval_path,
    );
    defer entity_cls.deinit();

    const dag = core.orchestration.dag_scheduler.DagScheduler{
        .embedding_svc = embedder,
        .vec_index = vec_idx,
        .sparse_idx = &sparse_idx,
        .doc_store = &doc_store,
        .neural_reranker = &neural_reranker,
        .entity_cls = &entity_cls,
    };

    var workload = try core.orchestration.workload_coordinator.WorkloadCoordinator.init(
        allocator,
        rt.config.orchestration,
        rt.config.storage,
        dag,
    );
    defer workload.deinit();

    var cache = try core.cache.cache_coordinator.HierarchicalCacheCoordinator.init(
        allocator,
        rt.config.cache,
        rt.config.model.model_version,
        1,
    );
    defer cache.deinit();

    var telemetry = core.telemetry.metrics.MetricsRegistry.init(
        rt.config.telemetry.trace_sample_permille,
        rt.config.telemetry.zscore_threshold_milli,
        rt.config.vector_index.shard_count,
    );

    var api_ctx = core.api.routes.EngineApiContext{
        .runtime = rt,
        .crawler = crawler,
        .stream = stream,
        .embedder = embedder,
        .trainer = trainer,
        .vec_idx = vec_idx,
        .sparse_idx = &sparse_idx,
        .workload = workload,
        .cache = cache,
        .doc_store = &doc_store,
        .telemetry = &telemetry,
    };

    if (run_once) {
        var req_arena = std.heap.ArenaAllocator.init(allocator);
        defer req_arena.deinit();
        const req_alloc = req_arena.allocator();

        const seed_req = "{\"url\":\"https://ziglang.org/documentation/master/\",\"title\":\"Zig Programming Language Reference\",\"html\":\"<html><head><title>Zig Programming Language Reference</title></head><body><h1>Zig SIMD Vector Operations</h1><p>Zig provides explicit @Vector SIMD types for x86_64 AVX-512, AVX2, and ARM NEON and SVE targets with deterministic allocator control.</p></body></html>\",\"priority\":true}";
        _ = try core.api.routes.dispatchHttpRequest(
            &api_ctx,
            req_alloc,
            .{
                .method = .POST,
                .path = "/ingest",
                .query_string = "",
                .content_type = "application/json",
                .body = seed_req,
            },
        );

        const search_req = "{\"query_text\":\"Zig SIMD AVX-512 vector operations\",\"top_k\":5,\"ranking_mode\":\"hybrid\",\"include_highlights\":true,\"verify_claims\":true,\"extract_entities\":true}";
        const search_resp = try core.api.routes.dispatchHttpRequest(
            &api_ctx,
            req_alloc,
            .{
                .method = .POST,
                .path = "/search",
                .query_string = "",
                .content_type = "application/json",
                .body = search_req,
            },
        );

        const stdout = std.io.getStdOut().writer();
        try stdout.print("{s}\n", .{search_resp.body});
        return;
    }

    var server = core.network.http_server.HttpServer.init(
        allocator,
        rt.config.api.bind_address,
        rt.config.api.port,
        @intCast(rt.config.api.max_request_body_bytes),
        &api_ctx,
        core.api.routes.dispatchHttpRequest,
    );
    try server.listenAndServe();
}
