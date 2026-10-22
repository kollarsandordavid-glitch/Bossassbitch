const std = @import("std");
const request_codec = @import("request_codec.zig");
const response_codec = @import("response_codec.zig");
const crawl_coordinator = @import("../crawl/crawl_coordinator.zig");
const stream_engine = @import("../ingestion/stream_engine.zig");
const embedding_service = @import("../models/embedding_service.zig");
const vector_index = @import("../index/vector_index.zig");
const sparse_index = @import("../retrieval/sparse_index.zig");
const document_store = @import("../storage/document_store.zig");
const cache_coordinator = @import("../cache/cache_coordinator.zig");
const metrics = @import("../telemetry/metrics.zig");
const http_server = @import("../network/http_server.zig");
const time_util = @import("../util/time.zig");

pub fn handleIngestionRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
    crawler: *crawl_coordinator.CrawlCoordinator,
    stream: *stream_engine.StreamEngine,
    embedder: *embedding_service.EmbeddingService,
    vec_idx: *vector_index.DistributedVectorIndex,
    sparse_idx: *sparse_index.SparseInvertedIndex,
    doc_store: *document_store.DocumentStore,
    cache: *cache_coordinator.HierarchicalCacheCoordinator,
    telemetry: *metrics.MetricsRegistry,
) !http_server.OutgoingHttpResponse {
    const sw = time_util.Stopwatch.start();
    _ = telemetry.ingest_requests_total.fetchAdd(1, .monotonic);

    const req = request_codec.parseIngestRequest(allocator, body) catch {
        _ = telemetry.api_errors_total.fetchAdd(1, .monotonic);
        return .{
            .status_code = 400,
            .content_type = "application/json",
            .body = try response_codec.encodeErrorJson(allocator, "invalid_ingest_request", "Missing or invalid document url or html/body_text"),
        };
    };

    const wrapped_html = if (std.mem.indexOfScalar(u8, req.html_or_body, '<') != null)
        try allocator.dupe(u8, req.html_or_body)
    else
        try std.fmt.allocPrint(allocator, "<html><head><title>{s}</title></head><body><p>{s}</p></body></html>", .{ req.title, req.html_or_body });
    defer allocator.free(wrapped_html);

    var extracted = try crawler.ingestHtmlPageDirectly(req.url, wrapped_html);
    defer extracted.deinit(crawler.allocator);

    const verdict = stream.filter.evaluateDocument(&extracted);
    _ = telemetry.crawler_monitor.observeExtraction(
        extracted.body_text.len,
        extracted.title.len > 0,
        verdict.quarantined,
    );

    if (!verdict.accepted) {
        var rej_buf = std.ArrayList(u8).init(allocator);
        try rej_buf.writer().print(
            "{{\"status\":\"filtered\",\"doc_id\":{d},\"reason\":\"{s}\",\"quality_permille\":{d},\"spam_permille\":{d}}}",
            .{ extracted.doc_id, verdict.reason, verdict.quality_score_permille, verdict.spam_probability_permille },
        );
        return .{
            .status_code = 202,
            .content_type = "application/json",
            .body = try rej_buf.toOwnedSlice(),
        };
    }

    const effective_title_const = if (extracted.title.len > 0) extracted.title else req.title;
    const owned_title = try allocator.dupe(u8, effective_title_const);
    defer allocator.free(owned_title);

    const seq_id = try stream.publishDocumentEvent(
        extracted.doc_id,
        extracted.domain_id,
        extracted.canonical_url,
        owned_title,
        extracted.body_text,
        extracted.language,
        extracted.published_at_ms,
        verdict.quality_score_permille,
        verdict.spam_probability_permille,
        req.priority,
    );

    try doc_store.putDocument(.{
        .doc_id = extracted.doc_id,
        .canonical_url = extracted.canonical_url,
        .original_url = extracted.original_url,
        .title = owned_title,
        .description = extracted.description,
        .body_text = extracted.body_text,
        .language = extracted.language,
        .domain_id = extracted.domain_id,
        .content_hash = extracted.content_hash,
        .simhash = extracted.simhash,
        .published_at_ms = extracted.published_at_ms,
        .fetched_at_ms = extracted.fetched_at_ms,
        .quality_permille = verdict.quality_score_permille,
    });

    try sparse_idx.indexDocumentFields(
        extracted.doc_id,
        owned_title,
        extracted.body_text,
        extracted.canonical_url,
    );

    const emb_out = try embedder.embedDocument(
        extracted.doc_id,
        owned_title,
        extracted.body_text,
        extracted.spans,
    );

    const centroid_id = try vec_idx.indexDocumentVector(
        extracted.doc_id,
        emb_out.model_version,
        &emb_out.primary_embedding,
        &emb_out.quantized_binary.packed_bytes,
        emb_out.original_norm,
        extracted.canonical_url,
        extracted.language,
        req.doc_type,
        extracted.published_at_ms,
        verdict.quality_score_permille,
    );

    if (req.priority) {
        const boundary = try vec_idx.refreshAndPublishGeneration(emb_out.model_version);
        cache.notifyIndexGenerationUpdate(boundary.generation_id);
    }

    telemetry.ingestion_latency.recordMicros(sw.elapsedMicros());

    var resp_buf = std.ArrayList(u8).init(allocator);
    try resp_buf.writer().print(
        "{{\"status\":\"indexed\",\"doc_id\":{d},\"stream_sequence_id\":{d},\"centroid_id\":{d},\"model_version\":{d},\"quality_score_permille\":{d},\"canonical_url\":",
        .{ extracted.doc_id, seq_id, centroid_id, emb_out.model_version, verdict.quality_score_permille },
    );
    try response_codec.writeJsonEscaped(resp_buf.writer(), extracted.canonical_url);
    try resp_buf.writer().writeByte('}');

    return .{
        .status_code = 201,
        .content_type = "application/json",
        .body = try resp_buf.toOwnedSlice(),
    };
}
