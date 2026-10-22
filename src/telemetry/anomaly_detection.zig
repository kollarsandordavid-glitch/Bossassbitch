const std = @import("std");

pub const RollingAnomalyDetector = struct {
    window: [128]f64,
    count: usize,
    cursor: usize,
    zscore_threshold: f64,
    anomalies_detected: u64,

    pub fn init(zscore_threshold_milli: u32) RollingAnomalyDetector {
        return .{
            .window = [_]f64{0.0} ** 128,
            .count = 0,
            .cursor = 0,
            .zscore_threshold = @as(f64, @floatFromInt(@max(1000, zscore_threshold_milli))) / 1000.0,
            .anomalies_detected = 0,
        };
    }

    pub fn observeAndCheckAnomaly(self: *RollingAnomalyDetector, sample: f64) bool {
        var is_anomaly = false;
        if (self.count >= 16) {
            var sum: f64 = 0.0;
            for (0..self.count) |i| sum += self.window[i];
            const mean = sum / @as(f64, @floatFromInt(self.count));

            var sq_sum: f64 = 0.0;
            for (0..self.count) |i| {
                const d = self.window[i] - mean;
                sq_sum += d * d;
            }
            const std_dev = @sqrt(sq_sum / @as(f64, @floatFromInt(self.count)) + 1e-6);
            const z = @abs(sample - mean) / std_dev;
            if (z >= self.zscore_threshold) {
                is_anomaly = true;
                self.anomalies_detected += 1;
            }
        }

        self.window[self.cursor] = sample;
        self.cursor = (self.cursor + 1) & 127;
        if (self.count < 128) self.count += 1;
        return is_anomaly;
    }
};
