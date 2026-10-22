const std = @import("std");

pub const NeumaierAccumulator = struct {
    sum: f64 = 0.0,
    compensation: f64 = 0.0,

    pub fn add(self: *NeumaierAccumulator, value: f32) void {
        if (!std.math.isFinite(value)) return;
        const x: f64 = @floatCast(value);
        const t = self.sum + x;
        if (@abs(self.sum) >= @abs(x)) {
            self.compensation += (self.sum - t) + x;
        } else {
            self.compensation += (x - t) + self.sum;
        }
        self.sum = t;
    }

    pub fn resultF32(self: NeumaierAccumulator) f32 {
        const res = self.sum + self.compensation;
        if (!std.math.isFinite(res)) return 0.0;
        return @floatCast(res);
    }
};

pub fn safeL2Norm(vec: []const f32) f32 {
    var acc = NeumaierAccumulator{};
    for (vec) |v| {
        if (std.math.isFinite(v)) {
            acc.add(v * v);
        }
    }
    const sq = @max(0.0, acc.resultF32());
    return @sqrt(sq);
}

pub fn normalizeInPlace(vec: []f32) f32 {
    const norm = safeL2Norm(vec);
    if (norm <= 1e-12) {
        const fill = 1.0 / @sqrt(@as(f32, @floatFromInt(@max(1, vec.len))));
        for (vec) |*v| v.* = fill;
        return 1.0;
    }
    const inv = 1.0 / norm;
    for (vec) |*v| {
        v.* = if (std.math.isFinite(v.*)) v.* * inv else 0.0;
    }
    return norm;
}

pub fn deterministicTieBreakLessThan(
    score_a: f32,
    doc_id_a: u64,
    score_b: f32,
    doc_id_b: u64,
) bool {
    const diff = score_a - score_b;
    if (@abs(diff) > 1e-7) {
        return score_a > score_b;
    }
    return doc_id_a < doc_id_b;
}
