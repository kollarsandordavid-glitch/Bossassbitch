const std = @import("std");

pub const LatencyHistogram = struct {
    buckets: [64]std.atomic.Value(u64),
    total_count: std.atomic.Value(u64),
    sum_micros: std.atomic.Value(u64),
    max_micros: std.atomic.Value(u64),

    pub fn init() LatencyHistogram {
        var hist: LatencyHistogram = undefined;
        for (0..64) |i| {
            hist.buckets[i] = std.atomic.Value(u64).init(0);
        }
        hist.total_count = std.atomic.Value(u64).init(0);
        hist.sum_micros = std.atomic.Value(u64).init(0);
        hist.max_micros = std.atomic.Value(u64).init(0);
        return hist;
    }

    pub fn recordMicros(self: *LatencyHistogram, micros: u64) void {
        const bucket_idx: usize = @min(63, @as(usize, @intCast(micros / 2000)));
        _ = self.buckets[bucket_idx].fetchAdd(1, .monotonic);
        _ = self.total_count.fetchAdd(1, .monotonic);
        _ = self.sum_micros.fetchAdd(micros, .monotonic);
        var prev_max = self.max_micros.load(.monotonic);
        while (micros > prev_max) {
            if (self.max_micros.cmpxchgWeak(prev_max, micros, .monotonic, .monotonic)) |actual| {
                prev_max = actual;
            } else break;
        }
    }

    pub fn percentileMicros(self: *const LatencyHistogram, quantile_permille: u32) u64 {
        const total = self.total_count.load(.monotonic);
        if (total == 0) return 0;
        const target = @max(1, (total * quantile_permille) / 1000);
        var cumulative: u64 = 0;
        for (0..64) |idx| {
            cumulative += self.buckets[idx].load(.monotonic);
            if (cumulative >= target) {
                return @as(u64, @intCast(idx + 1)) * 2000;
            }
        }
        return 128_000;
    }

    pub fn meanMicros(self: *const LatencyHistogram) u64 {
        const total = self.total_count.load(.monotonic);
        if (total == 0) return 0;
        return self.sum_micros.load(.monotonic) / total;
    }
};
