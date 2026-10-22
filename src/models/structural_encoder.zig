const std = @import("std");
const html_parser = @import("../crawl/html_parser.zig");

pub const STRUCTURAL_FEATURE_DIM: usize = 64;

pub const TokenStructuralContext = struct {
    dom_depth: u16,
    heading_level: u8,
    prominence_permille: u16,
    paragraph_index: u32,
    is_link_anchor: bool,
    relative_doc_position_permille: u16,
};

pub fn encodeStructuralFeatures(ctx: TokenStructuralContext) [STRUCTURAL_FEATURE_DIM]f32 {
    var feat: [STRUCTURAL_FEATURE_DIM]f32 = [_]f32{0.0} ** STRUCTURAL_FEATURE_DIM;

    const depth_norm = std.math.clamp(@as(f32, @floatFromInt(ctx.dom_depth)) / 64.0, 0.0, 1.0);
    const prom_norm = std.math.clamp(@as(f32, @floatFromInt(ctx.prominence_permille)) / 1000.0, 0.0, 1.0);
    const pos_norm = std.math.clamp(@as(f32, @floatFromInt(ctx.relative_doc_position_permille)) / 1000.0, 0.0, 1.0);
    const para_norm = std.math.clamp(@as(f32, @floatFromInt(ctx.paragraph_index)) / 128.0, 0.0, 1.0);

    feat[0] = depth_norm;
    feat[1] = prom_norm;
    feat[2] = pos_norm;
    feat[3] = para_norm;
    feat[4] = if (ctx.is_link_anchor) 1.0 else -0.25;

    if (ctx.heading_level >= 1 and ctx.heading_level <= 6) {
        feat[4 + ctx.heading_level] = 1.5;
    } else {
        feat[11] = 0.5;
    }

    for (12..STRUCTURAL_FEATURE_DIM) |idx| {
        const freq: f32 = @floatFromInt(idx - 11);
        const angle = (pos_norm * 3.14159265 * freq) + (depth_norm * 0.5 * freq);
        feat[idx] = if (idx % 2 == 0) @sin(angle) * prom_norm else @cos(angle) * (1.0 - depth_norm * 0.5);
    }
    return feat;
}

pub fn lookupContextForByteOffset(
    spans: []const html_parser.StructuralSpan,
    byte_offset: u32,
    total_doc_bytes: usize,
) TokenStructuralContext {
    const rel_pos: u16 = if (total_doc_bytes == 0)
        0
    else
        @intCast(@min(1000, (@as(u64, byte_offset) * 1000) / @as(u64, @intCast(total_doc_bytes))));

    for (spans) |sp| {
        if (byte_offset >= sp.byte_offset and byte_offset < sp.byte_offset + sp.byte_length) {
            return .{
                .dom_depth = sp.dom_depth,
                .heading_level = sp.heading_level,
                .prominence_permille = sp.prominence_permille,
                .paragraph_index = sp.paragraph_index,
                .is_link_anchor = sp.is_link_anchor,
                .relative_doc_position_permille = rel_pos,
            };
        }
    }

    return .{
        .dom_depth = 2,
        .heading_level = 0,
        .prominence_permille = 600,
        .paragraph_index = 0,
        .is_link_anchor = false,
        .relative_doc_position_permille = rel_pos,
    };
}
