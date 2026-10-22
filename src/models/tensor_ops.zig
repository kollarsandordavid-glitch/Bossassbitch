const std = @import("std");
const numeric_stability = @import("../scoring/numeric_stability.zig");

pub fn rmsNormInPlace(vec: []f32, eps: f32) void {
    if (vec.len == 0) return;
    var acc = numeric_stability.NeumaierAccumulator{};
    for (vec) |v| {
        acc.add(v * v);
    }
    const mean_sq = acc.resultF32() / @as(f32, @floatFromInt(vec.len));
    const inv_rms = 1.0 / @sqrt(@max(eps, mean_sq));
    for (vec) |*v| {
        v.* *= inv_rms;
    }
}

pub fn swiGluActivateInPlace(vec: []f32) void {
    for (vec) |*x| {
        const v = x.*;
        const sigmoid = 1.0 / (1.0 + @exp(-v));
        x.* = v * sigmoid;
    }
}

pub fn applyRotaryPositionalEncoding(vec: []f32, position: usize) void {
    const pos_f: f32 = @floatFromInt(position);
    var i: usize = 0;
    while (i + 1 < vec.len) : (i += 2) {
        const dim_ratio = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(vec.len));
        const freq = 1.0 / std.math.pow(f32, 10000.0, dim_ratio);
        const angle = pos_f * freq;
        const c = @cos(angle);
        const s = @sin(angle);
        const x0 = vec[i];
        const x1 = vec[i + 1];
        vec[i] = x0 * c - x1 * s;
        vec[i + 1] = x0 * s + x1 * c;
    }
}

pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    const len = @min(a.len, b.len);
    var dot = numeric_stability.NeumaierAccumulator{};
    var na = numeric_stability.NeumaierAccumulator{};
    var nb = numeric_stability.NeumaierAccumulator{};
    for (0..len) |i| {
        dot.add(a[i] * b[i]);
        na.add(a[i] * a[i]);
        nb.add(b[i] * b[i]);
    }
    const denom = @sqrt(@max(1e-12, na.resultF32())) * @sqrt(@max(1e-12, nb.resultF32()));
    return dot.resultF32() / denom;
}

pub fn matryoshkaTruncateAndNormalize(
    primary_4096: *const [4096]f32,
    out_retained_256: *[256]f32,
) f32 {
    @memcpy(out_retained_256[0..256], primary_4096[0..256]);
    return numeric_stability.normalizeInPlace(out_retained_256);
}
