const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const tensor = @import("tensor.zig");
const tensor_ops = @import("tensor_ops.zig");
const transformer = @import("transformer.zig");
const structural_encoder = @import("structural_encoder.zig");
const binary_scoring = @import("../scoring/binary_scoring.zig");
const numeric_stability = @import("../scoring/numeric_stability.zig");
const html_parser = @import("../crawl/html_parser.zig");
const hashing = @import("../util/hashing.zig");

pub const DualEncoderOutput = struct {
    model_version: u32,
    primary_embedding: [4096]f32,
    retained_embedding: [256]f32,
    quantized_binary: binary_scoring.QuantizedBinaryVector,
    original_norm: f32,
};

pub const DualEncoderModel = struct {
    allocator: std.mem.Allocator,
    model_version: u32,
    tok: tokenizer.SubwordTokenizer,
    block: transformer.TransformerBlock,
    learned_temperature: f32,
    projection_seed: u64,

    pub fn init(allocator: std.mem.Allocator, model_version: u32, vocab_size: u32, max_seq_len: u32) DualEncoderModel {
        return .{
            .allocator = allocator,
            .model_version = model_version,
            .tok = tokenizer.SubwordTokenizer.init(vocab_size, max_seq_len),
            .block = transformer.TransformerBlock.init(64, 4),
            .learned_temperature = 0.07,
            .projection_seed = 0x4d617472796f7368 +% @as(u64, model_version),
        };
    }

    pub fn encodeQuery(self: *DualEncoderModel, query_text: []const u8) !DualEncoderOutput {
        return self.encodeStructuredDocument(query_text, "", &.{});
    }

    pub fn encodeStructuredDocument(
        self: *DualEncoderModel,
        title: []const u8,
        body_text: []const u8,
        spans: []const html_parser.StructuralSpan,
    ) !DualEncoderOutput {
        var combined = std.ArrayList(u8).init(self.allocator);
        defer combined.deinit();
        if (title.len > 0) {
            try combined.appendSlice(title);
            try combined.append('\n');
        }
        try combined.appendSlice(body_text);

        const token_spans = try self.tok.encodeText(self.allocator, combined.items);
        defer self.allocator.free(token_spans);

        const seq_len = @min(token_spans.len, 128);
        var hidden = try tensor.Tensor2D.initZeros(self.allocator, seq_len, 64);
        defer hidden.deinit();

        for (0..seq_len) |idx| {
            const ts = token_spans[idx];
            const struct_ctx = structural_encoder.lookupContextForByteOffset(
                spans,
                ts.byte_offset,
                combined.items.len,
            );
            const struct_feat = structural_encoder.encodeStructuralFeatures(struct_ctx);
            const row = hidden.rowSlice(idx);

            for (0..64) |d| {
                const token_phase = @as(f32, @floatFromInt((ts.token_id *% @as(u32, @intCast(d + 17))) & 1023)) / 512.0 - 1.0;
                row[d] = token_phase * 0.7 + struct_feat[d] * 0.3;
            }
        }

        try self.block.forwardInPlace(self.allocator, &hidden);

        var pooled: [64]f32 = [_]f32{0.0} ** 64;
        for (0..seq_len) |r| {
            const row = hidden.rowSlice(r);
            const weight: f32 = if (r == 0) 1.5 else 1.0;
            for (0..64) |c| {
                pooled[c] += row[c] * weight;
            }
        }

        var primary: [4096]f32 = [_]f32{0.0} ** 4096;
        for (0..4096) |dim_idx| {
            const base_c = dim_idx & 63;
            const pair_c = (dim_idx * 7 + 13) & 63;
            const harmonic = @sin(@as(f32, @floatFromInt(dim_idx + 1)) * 0.0174532925);
            primary[dim_idx] = pooled[base_c] * 0.65 + pooled[pair_c] * 0.35 * harmonic;
        }

        var tok_iter = std.mem.tokenizeAny(u8, combined.items, " \t\r\n.,;:!?()[]{}<>\"'");
        while (tok_iter.next()) |word| {
            if (word.len < 2) continue;
            var lower_buf: [48]u8 = undefined;
            const wlen = @min(word.len, lower_buf.len);
            for (word[0..wlen], 0..) |ch, i| {
                lower_buf[i] = std.ascii.toLower(ch);
            }
            const h1 = hashing.wyhash64(lower_buf[0..wlen], self.projection_seed);
            const h2 = hashing.wyhash64(lower_buf[0..wlen], self.projection_seed ^ 0x9e3779b97f4a7c15);

            const m_idx: usize = @intCast(h1 & 255);
            const m_sign: f32 = if ((h1 & 256) != 0) 1.8 else -1.8;
            primary[m_idx] += m_sign;

            const p_idx: usize = 256 + @as(usize, @intCast(h2 % (4096 - 256)));
            const p_sign: f32 = if ((h2 & 512) != 0) 1.4 else -1.4;
            primary[p_idx] += p_sign;
        }

        const orig_norm = numeric_stability.safeL2Norm(&primary);
        _ = numeric_stability.normalizeInPlace(&primary);

        var retained: [256]f32 = undefined;
        _ = tensor_ops.matryoshkaTruncateAndNormalize(&primary, &retained);

        const q_bin = binary_scoring.quantizeRetained256(&retained, .{
            .zero_threshold = 0.0,
            .enable_stochastic_dithering = false,
        });

        return .{
            .model_version = self.model_version,
            .primary_embedding = primary,
            .retained_embedding = retained,
            .quantized_binary = .{
                .quantization_version = q_bin.quantization_version,
                .packed_bytes = q_bin.packed_bytes,
                .original_l2_norm = orig_norm,
                .set_bits_count = q_bin.set_bits_count,
            },
            .original_norm = orig_norm,
        };
    }
};
