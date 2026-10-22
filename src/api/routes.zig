const std = @import("std");
const http_server = @import("../network/http_server.zig");
const request_codec = @import("request_codec.zig");
const response_codec = @import("response_codec.zig");
const search_handler = @import("search_handler.zig");
const ingestion_handler = @import("ingestion_handler.zig");
const research_handler = @import("research_handler.zig");
const highlights_handler = @import("highlights_handler.zig");
const entity_handler = @import("entity_handler.zig");
const lifecycle = @import("../runtime/lifecycle.zig");
const crawl_coordinator = @import("../crawl/crawl_coordinator.zig");
const stream_engine = @import("../ingestion/stream_engine.zig");
const embedding_service = @import("../models/embedding_service.zig");
const training_coordinator = @import("../training/training_coordinator.zig");
const vector_index = @import("../index/vector_index.zig");
const sparse_index = @import("../retrieval/sparse_index.zig");
const workload_coordinator = @import("../orchestration/workload_coordinator.zig");
const cache_coordinator = @import("../cache/cache_coordinator.zig");
const document_store = @import("../storage/document_store.zig");
const metrics = @import("../telemetry/metrics.zig");
const exporters = @import("../telemetry/exporters.zig");

pub const EngineApiContext = struct {
    runtime: *lifecycle.RuntimeLifecycle,
    crawler: *crawl_coordinator.CrawlCoordinator,
    stream: *stream_engine.StreamEngine,
    embedder: *embedding_service.EmbeddingService,
    trainer: *training_coordinator.TrainingCoordinator,
    vec_idx: *vector_index.DistributedVectorIndex,
    sparse_idx: *sparse_index.SparseInvertedIndex,
    workload: *workload_coordinator.WorkloadCoordinator,
    cache: *cache_coordinator.HierarchicalCacheCoordinator,
    doc_store: *document_store.DocumentStore,
    telemetry: *metrics.MetricsRegistry,
};

pub fn dispatchHttpRequest(
    raw_ctx: *anyopaque,
    allocator: std.mem.Allocator,
    req: http_server.IncomingHttpRequest,
) !http_server.OutgoingHttpResponse {
    const ctx: *EngineApiContext = @ptrCast(@alignCast(raw_ctx));

    if (!ctx.runtime.beginRequest()) {
        return .{
            .status_code = 503,
            .content_type = "application/json",
            .body = try response_codec.encodeErrorJson(allocator, "node_draining", "Node is draining or not ready"),
        };
    }
    defer ctx.runtime.endRequest();

    if (req.method == .GET and std.mem.eql(u8, req.path, "/health")) {
        const vis = ctx.vec_idx.consistency_coord.acquireReadBoundary();
        var buf = std.ArrayList(u8).init(allocator);
        try buf.writer().print(
            "{{\"status\":\"ready\",\"node_id\":\"{s}\",\"simd_backend\":\"{s}\",\"index_generation\":{d},\"model_version\":{d},\"indexed_documents\":{d},\"heap_used_bytes\":{d}}}",
            .{
                ctx.runtime.config.runtime.node_id,
                @tagName(ctx.runtime.topology.preferred_simd),
                vis.generation_id,
                vis.model_version,
                ctx.vec_idx.total_indexed_docs.load(.monotonic),
                ctx.runtime.bounded_allocator.usedBytes(),
            },
        );
        return .{
            .status_code = 200,
            .content_type = "application/json",
            .body = try buf.toOwnedSlice(),
        };
    }

    if (req.method == .GET and std.mem.eql(u8, req.path, "/metrics")) {
        const vis = ctx.vec_idx.consistency_coord.acquireReadBoundary();
        const hits = ctx.cache.response_cache.hits.load(.monotonic) + ctx.cache.embedding_cache.hits.load(.monotonic);
        const misses = ctx.cache.response_cache.misses.load(.monotonic) + ctx.cache.embedding_cache.misses.load(.monotonic);
        const body = try exporters.formatMetricsJson(
            allocator,
            ctx.telemetry,
            ctx.vec_idx.total_indexed_docs.load(.monotonic),
            vis.generation_id,
            vis.model_version,
            hits,
            misses,
        );
        return .{
            .status_code = 200,
            .content_type = "application/json",
            .body = body,
        };
    }

    if (req.method == .GET and std.mem.eql(u8, req.path, "/index/status")) {
        const vis = ctx.vec_idx.consistency_coord.acquireReadBoundary();
        var buf = std.ArrayList(u8).init(allocator);
        try buf.writer().print(
            "{{\"status\":\"ok\",\"index_generation\":{d},\"commit_sequence\":{d},\"model_version\":{d},\"shard_count\":{d},\"semantic_centroids\":{d},\"total_documents\":{d},\"deleted_tombstones\":{d}}}",
            .{
                vis.generation_id,
                vis.commit_sequence,
                vis.model_version,
                ctx.vec_idx.shards.shards.len,
                ctx.vec_idx.centroids.total_centroids,
                ctx.vec_idx.total_indexed_docs.load(.monotonic),
                ctx.vec_idx.deletions.tombstone_count.load(.monotonic),
            },
        );
        return .{
            .status_code = 200,
            .content_type = "application/json",
            .body = try buf.toOwnedSlice(),
        };
    }

    if (req.method == .POST and std.mem.eql(u8, req.path, "/search")) {
        return search_handler.handleSearchRequest(
            allocator,
            req.body,
            ctx.workload,
            ctx.cache,
            ctx.telemetry,
        );
    }

    if (req.method == .POST and std.mem.eql(u8, req.path, "/ingest")) {
        return ingestion_handler.handleIngestionRequest(
            allocator,
            req.body,
            ctx.crawler,
            ctx.stream,
            ctx.embedder,
            ctx.vec_idx,
            ctx.sparse_idx,
            ctx.doc_store,
            ctx.cache,
            ctx.telemetry,
        );
    }

    if (req.method == .POST and std.mem.eql(u8, req.path, "/research")) {
        return research_handler.handleStartResearchRequest(allocator, req.body, ctx.workload);
    }

    if (req.method == .GET and std.mem.startsWith(u8, req.path, "/research/")) {
        const job_id = req.path["/research/".len..];
        return research_handler.handleGetResearchStatusRequest(allocator, job_id, ctx.workload);
    }

    if (req.method == .POST and std.mem.eql(u8, req.path, "/highlights")) {
        return highlights_handler.handleHighlightsRequest(allocator, req.body, ctx.doc_store);
    }

    if (req.method == .POST and std.mem.eql(u8, req.path, "/entities")) {
        return entity_handler.handleEntityExtractionRequest(
            allocator,
            req.body,
            ctx.workload.dag.entity_cls,
            ctx.doc_store,
        );
    }

    if (req.method == .POST and std.mem.eql(u8, req.path, "/index/refresh")) {
        const active_ver = ctx.embedder.registry.active_version.load(.acquire);
        const boundary = try ctx.vec_idx.refreshAndPublishGeneration(active_ver);
        ctx.cache.notifyIndexGenerationUpdate(boundary.generation_id);
        var buf = std.ArrayList(u8).init(allocator);
        try buf.writer().print(
            "{{\"status\":\"published\",\"generation_id\":{d},\"commit_sequence\":{d},\"model_version\":{d}}}",
            .{ boundary.generation_id, boundary.commit_sequence, boundary.model_version },
        );
        return .{
            .status_code = 200,
            .content_type = "application/json",
            .body = try buf.toOwnedSlice(),
        };
    }

    if (req.method == .POST and std.mem.eql(u8, req.path, "/models/refresh")) {
        const mreq = request_codec.parseModelRefreshRequest(allocator, req.body) catch {
            return .{
                .status_code = 400,
                .content_type = "application/json",
                .body = try response_codec.encodeErrorJson(allocator, "invalid_model_refresh", "Invalid model refresh body"),
            };
        };
        ctx.trainer.active_model_version = mreq.model_version;
        const train_metrics = try ctx.trainer.runTrainingIterationAndCheckpoint();
        var ckpt_name_buf: [256]u8 = undefined;
        const ckpt_file = if (mreq.checkpoint_file.len > 0)
            mreq.checkpoint_file
        else
            try std.fmt.bufPrint(&ckpt_name_buf, "model_v{d}_step{d}.ckpt", .{ mreq.model_version, train_metrics.global_step });

        const desc = try ctx.embedder.registry.registerAndActivateCheckpoint(
            &ctx.embedder.ckpt_mgr,
            ckpt_file,
            train_metrics.curriculum_stage,
            train_metrics.global_step,
        );
        ctx.vec_idx.consistency_coord.active_model_version.store(desc.model_version, .release);
        ctx.cache.notifyModelRollout(desc.model_version);

        var buf = std.ArrayList(u8).init(allocator);
        try buf.writer().print(
            "{{\"status\":\"rolled_out\",\"model_version\":{d},\"curriculum_stage\":{d},\"global_step\":{d},\"learned_temperature\":{d:.4}}}",
            .{ desc.model_version, train_metrics.curriculum_stage, train_metrics.global_step, desc.learned_temperature },
        );
        return .{
            .status_code = 200,
            .content_type = "application/json",
            .body = try buf.toOwnedSlice(),
        };
    }

    return .{
        .status_code = 404,
        .content_type = "application/json",
        .body = try response_codec.encodeErrorJson(allocator, "route_not_found", "Endpoint does not exist"),
    };
}
