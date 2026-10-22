const std = @import("std");
const metrics = @import("metrics.zig");

pub fn formatMetricsJson(
    allocator: std.mem.Allocator,
    reg: *const metrics.MetricsRegistry,
    indexed_docs: u64,
    active_generation: u64,
    active_model_version: u32,
    cache_hits: u64,
    cache_misses: u64,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    const p50_us = reg.search_latency.percentileMicros(500);
    const p95_us = reg.search_latency.percentileMicros(950);
    const p99_us = reg.search_latency.percentileMicros(990);

    try out.writer().print(
        "{{" ++
            "\"search_requests_total\":{d}," ++
            "\"ingest_requests_total\":{d}," ++
            "\"api_errors_total\":{d}," ++
            "\"indexed_documents\":{d}," ++
            "\"active_index_generation\":{d}," ++
            "\"active_model_version\":{d}," ++
            "\"search_latency_p50_micros\":{d}," ++
            "\"search_latency_p95_micros\":{d}," ++
            "\"search_latency_p99_micros\":{d}," ++
            "\"cache_hits\":{d}," ++
            "\"cache_misses\":{d}," ++
            "\"crawler_template_shift_alerts\":{d}," ++
            "\"crawler_honeypot_quarantines\":{d}," ++
            "\"model_drift_score_milli\":{d}," ++
            "\"healthy_shards\":{d}" ++
            "}}",
        .{
            reg.search_requests_total.load(.monotonic),
            reg.ingest_requests_total.load(.monotonic),
            reg.api_errors_total.load(.monotonic),
            indexed_docs,
            active_generation,
            active_model_version,
            p50_us,
            p95_us,
            p99_us,
            cache_hits,
            cache_misses,
            reg.crawler_monitor.template_shift_alerts.load(.monotonic),
            reg.crawler_monitor.honeypot_quarantine_alerts.load(.monotonic),
            reg.drift_monitor.latest_drift_score_milli.load(.monotonic),
            reg.index_monitor.healthy_shards.load(.monotonic),
        },
    );

    return out.toOwnedSlice();
}
