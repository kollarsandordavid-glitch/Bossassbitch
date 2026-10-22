const std = @import("std");
const tensor = @import("tensor.zig");
const tensor_ops = @import("tensor_ops.zig");
const attention = @import("attention.zig");

pub const TransformerBlock = struct {
    hidden_dim: usize,
    num_heads: usize,
    ffn_up_scale: f32,

    pub fn init(hidden_dim: usize, num_heads: usize) TransformerBlock {
        return .{
            .hidden_dim = hidden_dim,
            .num_heads = num_heads,
            .ffn_up_scale = 1.15,
        };
    }

    pub fn forwardInPlace(
        self: TransformerBlock,
        allocator: std.mem.Allocator,
        hidden_states: *tensor.Tensor2D,
    ) !void {
        for (0..hidden_states.rows) |r| {
            const row = hidden_states.rowSlice(r);
            tensor_ops.rmsNormInPlace(row, 1e-6);
            tensor_ops.applyRotaryPositionalEncoding(row, r);
        }

        var attn_out = try attention.computeScaledDotProductAttention(
            allocator,
            hidden_states,
            .{
                .hidden_dim = self.hidden_dim,
                .num_heads = self.num_heads,
                .use_flash_tiling = true,
            },
        );
        defer attn_out.deinit();

        for (0..hidden_states.rows) |r| {
            const h_row = hidden_states.rowSlice(r);
            const a_row = attn_out.rowSlice(r);
            for (0..hidden_states.cols) |c| {
                h_row[c] += a_row[c];
            }
            tensor_ops.rmsNormInPlace(h_row, 1e-6);
            for (0..hidden_states.cols) |c| {
                const prev = h_row[c];
                const next = if (c + 1 < hidden_states.cols) h_row[c + 1] else h_row[0];
                const activated = (prev * self.ffn_up_scale) / (1.0 + @exp(-next));
                h_row[c] = prev + activated * 0.25;
            }
            tensor_ops.rmsNormInPlace(h_row, 1e-6);
        }
    }
};
