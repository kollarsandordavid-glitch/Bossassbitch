const std = @import("std");
const tensor = @import("tensor.zig");
const numeric_stability = @import("../scoring/numeric_stability.zig");

pub const MultiHeadAttentionConfig = struct {
    hidden_dim: usize = 64,
    num_heads: usize = 4,
    use_flash_tiling: bool = true,
};

pub fn computeScaledDotProductAttention(
    allocator: std.mem.Allocator,
    sequence_states: *const tensor.Tensor2D,
    cfg: MultiHeadAttentionConfig,
) !tensor.Tensor2D {
    const seq_len = sequence_states.rows;
    const dim = sequence_states.cols;
    var out = try tensor.Tensor2D.initZeros(allocator, seq_len, dim);
    errdefer out.deinit();

    if (seq_len == 0 or dim == 0) return out;
    const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(@max(1, dim / @max(1, cfg.num_heads)))));

    var scores = try allocator.alloc(f32, seq_len);
    defer allocator.free(scores);

    for (0..seq_len) |q_idx| {
        const q_row = sequence_states.rowSlice(q_idx);
        var max_score: f32 = -1e30;

        for (0..seq_len) |k_idx| {
            const k_row = sequence_states.rowSlice(k_idx);
            var dot: f32 = 0.0;
            for (0..dim) |d| {
                dot += q_row[d] * k_row[d];
            }
            const s = dot * scale;
            scores[k_idx] = s;
            if (s > max_score) max_score = s;
        }

        var sum_exp = numeric_stability.NeumaierAccumulator{};
        for (0..seq_len) |k_idx| {
            const e = @exp(scores[k_idx] - max_score);
            scores[k_idx] = e;
            sum_exp.add(e);
        }
        const inv_denom = 1.0 / @max(1e-12, sum_exp.resultF32());

        const out_row = out.rowSlice(q_idx);
        for (0..seq_len) |v_idx| {
            const weight = scores[v_idx] * inv_denom;
            const v_row = sequence_states.rowSlice(v_idx);
            for (0..dim) |d| {
                out_row[d] += weight * v_row[d];
            }
        }
    }

    return out;
}
