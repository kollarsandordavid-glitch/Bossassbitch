const std = @import("std");

pub const IndexHealthTelemetry = struct {
    centroid_imbalance_permille: std.atomic.Value(u32),
    max_replication_lag_seq: std.atomic.Value(u64),
    delayed_publications: std.atomic.Value(u64),
    healthy_shards: std.atomic.Value(u32),
    compaction_runs_total: std.atomic.Value(u64),

    pub fn init(shard_count: u32) IndexHealthTelemetry {
        return .{
            .centroid_imbalance_permille = std.atomic.Value(u32).init(0),
            .max_replication_lag_seq = std.atomic.Value(u64).init(0),
            .delayed_publications = std.atomic.Value(u64).init(0),
            .healthy_shards = std.atomic.Value(u32).init(shard_count),
            .compaction_runs_total = std.atomic.Value(u64).init(0),
        };
    }

    pub fn observeClusterSizes(self: *IndexHealthTelemetry, cluster_sizes: []const u64) u32 {
        if (cluster_sizes.len == 0) return 0;
        var sum: f64 = 0.0;
        for (cluster_sizes) |sz| {
            sum += @floatFromInt(sz);
        }
        const mean = sum / @as(f64, @floatFromInt(cluster_sizes.len));
        if (mean <= 1e-6) {
            self.centroid_imbalance_permille.store(0, .monotonic);
            return 0;
        }
        var var_sum: f64 = 0.0;
        for (cluster_sizes) |sz| {
            const diff = @as(f64, @floatFromInt(sz)) - mean;
            var_sum += diff * diff;
        }
        const std_dev = @sqrt(var_sum / @as(f64, @floatFromInt(cluster_sizes.len)));
        const cv_permille: u32 = @intFromFloat(std.math.clamp((std_dev / mean) * 1000.0, 0.0, 10000.0));
        self.centroid_imbalance_permille.store(cv_permille, .monotonic);
        return cv_permille;
    }

    pub fn recordReplicationLag(self: *IndexHealthTelemetry, primary_seq: u64, replica_min_seq: u64) void {
        const lag = primary_seq -| replica_min_seq;
        self.max_replication_lag_seq.store(lag, .monotonic);
    }
};
