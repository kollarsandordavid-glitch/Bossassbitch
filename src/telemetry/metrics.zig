const std = @import("std");
const latency_histograms = @import("latency_histograms.zig");
const tracing = @import("tracing.zig");
const crawler_anomalies = @import("crawler_anomalies.zig");
const model_drift = @import("model_drift.zig");
const index_health = @import("index_health.zig");

pub const MetricsRegistry = struct {
    search_latency: latency_histograms.LatencyHistogram,
    ingestion_latency: latency_histograms.LatencyHistogram,
    tracer: tracing.DistributedTracer,
    crawler_monitor: crawler_anomalies.CrawlerAnomalyMonitor,
    drift_monitor: model_drift.ModelDriftTelemetry,
    index_monitor: index_health.IndexHealthTelemetry,
    search_requests_total: std.atomic.Value(u64),
    ingest_requests_total: std.atomic.Value(u64),
    api_errors_total: std.atomic.Value(u64),

    pub fn init(sample_permille: u32, zscore_threshold_milli: u32, shard_count: u32) MetricsRegistry {
        return .{
            .search_latency = latency_histograms.LatencyHistogram.init(),
            .ingestion_latency = latency_histograms.LatencyHistogram.init(),
            .tracer = tracing.DistributedTracer.init(sample_permille),
            .crawler_monitor = crawler_anomalies.CrawlerAnomalyMonitor.init(zscore_threshold_milli),
            .drift_monitor = model_drift.ModelDriftTelemetry.init(),
            .index_monitor = index_health.IndexHealthTelemetry.init(shard_count),
            .search_requests_total = std.atomic.Value(u64).init(0),
            .ingest_requests_total = std.atomic.Value(u64).init(0),
            .api_errors_total = std.atomic.Value(u64).init(0),
        };
    }
};
