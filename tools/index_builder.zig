const std = @import("std");
const core = @import("engine_core");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_dir: []const u8 = "./settings";
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--config-dir=")) {
            config_dir = arg["--config-dir=".len..];
        }
    }

    var cfg = try core.runtime.configuration.SystemConfiguration.loadFromDirectory(allocator, config_dir);
    defer cfg.deinit();

    var embedder = try core.models.embedding_service.EmbeddingService.init(allocator, cfg.model);
    defer embedder.deinit();

    var vec_idx = try core.index.vector_index.DistributedVectorIndex.init(
        allocator,
        cfg.vector_index,
        cfg.model.model_version,
    );
    defer vec_idx.deinit();

    var doc_store = try core.storage.document_store.DocumentStore.init(allocator, cfg.storage.document_store_path);
    defer doc_store.deinit();

    var indexed_count: u64 = 0;
    var it = doc_store.documents.valueIterator();
    while (it.next()) |doc| {
        const emb = try embedder.embedDocument(doc.doc_id, doc.title, doc.body_text, &.{});
        _ = try vec_idx.indexDocumentVector(
            doc.doc_id,
            emb.model_version,
            &emb.primary_embedding,
            &emb.quantized_binary.packed_bytes,
            emb.original_norm,
            doc.canonical_url,
            doc.language,
            "web_page",
            doc.published_at_ms,
            doc.quality_permille,
        );
        indexed_count += 1;
    }

    const boundary = try vec_idx.refreshAndPublishGeneration(cfg.model.model_version);
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "{{\"tool\":\"index-builder\",\"status\":\"completed\",\"documents_built\":{d},\"generation_id\":{d},\"commit_sequence\":{d}}}\n",
        .{ indexed_count, boundary.generation_id, boundary.commit_sequence },
    );
}
