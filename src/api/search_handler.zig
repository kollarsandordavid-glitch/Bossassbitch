const std = @import("std");
const request_codec = @import("request_codec.zig");
const response_codec = @import("response_codec.zig");
const workload_coordinator = @import("../orchestration/workload_coordinator.zig");
const cache_coordinator = @import("../cache/cache_coordinator.zig");
const invalidation = @import("../cache/invalidation.zig");
const metrics = @import("../telemetry/metrics.zig");
const http_server = @import("../network/http_server.zig");
const time_util = @import("../util/time.zig");

pub fn handleSearchRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
    coord: *workload_coordinator.WorkloadCoordinator,
    cache: *cache_coordinator.HierarchicalCacheCoordinator,
    telemetry: *metrics.MetricsRegistry,
) !http_server.OutgoingHttpResponse {
    const sw = time_util.Stopwatch.start();
    _ = telemetry.search_requests_total.fetchAdd(1, .monotonic);

    const req = request_codec.parseSearchRequest(allocator, body) catch {
        _ = telemetry.api_errors_total.fetchAdd(1, .monotonic);
        return .{
            .status_code = 400,
            .content_type = "application/json",
            .body = try response_codec.encodeErrorJson(allocator, "invalid_search_request", "Invalid or missing search query parameters"),
        };
    };

    const visibility = coord.dag.vec_index.consistency_coord.acquireReadBoundary();
    const cache_key = invalidation.CanonicalCacheKey.build(
        req.query_text,
        req.ranking_mode,
        req.top_k,
        req.min_quality_permille,
        visibility.model_version,
        visibility.generation_id,
    );

    if (try cache.response_cache.lookupRenderedJson(
        allocator,
        cache_key,
        visibility.model_version,
        visibility.generation_id,
    )) |cached_json| {
        telemetry.search_latency.recordMicros(sw.elapsedMicros());
        return .{
            .status_code = 200,
            .content_type = "application/json",
            .body = cached_json,
        };
    }

    var dag_res = try coord.dag.executeQueryDag(allocator, .{
        .query_text = req.query_text,
        .ranking_mode = req.ranking_mode,
        .top_k = req.top_k,
        .candidate_pool_k = req.candidate_pool_k,
        .deadline_ms = req.deadline_ms,
        .include_highlights = req.include_highlights,
        .verify_claims = req.verify_claims,
        .extract_entities = req.extract_entities,
        .filters = .{
            .min_quality_permille = req.min_quality_permille,
        },
    });
    defer dag_res.deinit(allocator);

    _ = coord.interactive_queries_served.fetchAdd(1, .monotonic);
    try coord.pareto_analyzer.recordObservation(
        req.candidate_pool_k,
        @intCast(dag_res.ranked_candidates.len),
        910,
        dag_res.node_durations_micros[5],
        dag_res.total_elapsed_ms,
    );

    const rendered = try response_codec.encodeSearchDagResponseJson(
        allocator,
        &dag_res,
        coord.dag.doc_store,
        false,
    );

    try cache.response_cache.storeRenderedJson(cache_key, rendered);
    telemetry.search_latency.recordMicros(sw.elapsedMicros());

    return .{
        .status_code = 200,
        .content_type = "application/json",
        .body = rendered,
    };
}
