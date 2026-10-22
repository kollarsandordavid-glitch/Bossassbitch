const std = @import("std");

pub const ModelDriftTelemetry = struct {
    latest_drift_score_milli: std.atomic.Value(u32),
    recalibration_triggers: std.atomic.Value(u64),
    embedding_norm_mean_milli: std.atomic.Value(u32),
    lexical_disagreement_milli: std.atomic.Value(u32),

    pub fn init() ModelDriftTelemetry {
        return .{
            .latest_drift_score_milli = std.atomic.Value(u32).init(0),
            .recalibration_triggers = std.atomic.Value(u64).init(0),
            .embedding_norm_mean_milli = std.atomic.Value(u32).init(1000),
            .lexical_disagreement_milli = std.atomic.Value(u32).init(0),
        };
    }

    pub fn recordDriftScore(self: *ModelDriftTelemetry, drift_milli: u32, triggered: bool) void {
        self.latest_drift_score_milli.store(drift_milli, .monotonic);
        if (triggered) {
            _ = self.recalibration_triggers.fetchAdd(1, .monotonic);
        }
    }

    pub fn observeEmbeddingNorm(self: *ModelDriftTelemetry, norm: f32) void {
        if (!std.math.isFinite(norm) or norm <= 0.0) return;
        const norm_milli: u32 = @intFromFloat(std.math.clamp(norm * 1000.0, 1.0, 100000.0));
        const prev = self.embedding_norm_mean_milli.load(.monotonic);
        const updated = (prev * 9 + norm_milli) / 10;
        self.embedding_norm_mean_milli.store(updated, .monotonic);
    }
};
