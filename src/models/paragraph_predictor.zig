const std = @import("std");
const tensor_ops = @import("tensor_ops.zig");

pub const PredictedParagraphBoundary = struct {
    paragraph_index: u32,
    byte_start: u32,
    byte_end: u32,
    coherence_score: f32,
    global_conditioning_score: f32,
    parent_heading_offset: u32,
};

pub const ParagraphPredictor = struct {
    min_paragraph_bytes: u32 = 32,
    max_paragraph_bytes: u32 = 1024,

    pub fn predictParagraphs(
        self: ParagraphPredictor,
        allocator: std.mem.Allocator,
        body_text: []const u8,
        global_retained_embedding: *const [256]f32,
    ) ![]PredictedParagraphBoundary {
        var boundaries = std.ArrayList(PredictedParagraphBoundary).init(allocator);
        errdefer boundaries.deinit();

        if (body_text.len == 0) return boundaries.toOwnedSlice();

        var global_energy: f32 = 0.0;
        for (global_retained_embedding[0..32]) |v| {
            global_energy += @abs(v);
        }
        const cond_base = std.math.clamp(global_energy / 32.0, 0.1, 1.0);

        var start: usize = 0;
        var p_idx: u32 = 0;
        var last_heading_offset: u32 = 0;

        var i: usize = 0;
        while (i < body_text.len) : (i += 1) {
            const span_len = i - start;
            const is_newline = body_text[i] == '\n';
            const is_sentence_break = (body_text[i] == '.' or body_text[i] == '!' or body_text[i] == '?') and
                (i + 1 < body_text.len and std.ascii.isWhitespace(body_text[i + 1]));

            if ((is_newline and span_len >= self.min_paragraph_bytes) or
                (is_sentence_break and span_len >= 240) or
                (span_len >= self.max_paragraph_bytes))
            {
                const end_pos = i + 1;
                const slice = std.mem.trim(u8, body_text[start..end_pos], " \t\r\n");
                if (slice.len > 0) {
                    if (slice.len < 96 and std.ascii.isUpper(slice[0])) {
                        last_heading_offset = @intCast(start);
                    }
                    const coherence = computeSpanCoherence(slice, cond_base);
                    try boundaries.append(.{
                        .paragraph_index = p_idx,
                        .byte_start = @intCast(start),
                        .byte_end = @intCast(end_pos),
                        .coherence_score = coherence,
                        .global_conditioning_score = cond_base,
                        .parent_heading_offset = last_heading_offset,
                    });
                    p_idx += 1;
                }
                start = end_pos;
            }
        }

        if (start < body_text.len) {
            const slice = std.mem.trim(u8, body_text[start..], " \t\r\n");
            if (slice.len > 0) {
                const coherence = computeSpanCoherence(slice, cond_base);
                try boundaries.append(.{
                    .paragraph_index = p_idx,
                    .byte_start = @intCast(start),
                    .byte_end = @intCast(body_text.len),
                    .coherence_score = coherence,
                    .global_conditioning_score = cond_base,
                    .parent_heading_offset = last_heading_offset,
                });
            }
        }
        _ = tensor_ops;
        return boundaries.toOwnedSlice();
    }
};

fn computeSpanCoherence(slice: []const u8, cond_base: f32) f32 {
    var words: u32 = 0;
    var iter = std.mem.tokenizeAny(u8, slice, " \t\r\n");
    while (iter.next()) |_| words += 1;
    const length_factor = std.math.clamp(@as(f32, @floatFromInt(words)) / 45.0, 0.2, 1.0);
    return std.math.clamp(length_factor * 0.75 + cond_base * 0.25, 0.0, 1.0);
}
