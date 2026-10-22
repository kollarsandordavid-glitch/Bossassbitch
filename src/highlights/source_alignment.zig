const std = @import("std");

pub const SourceAlignmentVerification = struct {
    aligned: bool,
    verified_byte_start: u32,
    verified_byte_end: u32,
};

pub fn verifyPassageInSourceDocument(
    source_body_text: []const u8,
    claimed_byte_start: u32,
    claimed_byte_end: u32,
    passage_text: []const u8,
) SourceAlignmentVerification {
    if (passage_text.len == 0 or source_body_text.len == 0) {
        return .{ .aligned = false, .verified_byte_start = 0, .verified_byte_end = 0 };
    }

    const s_idx: usize = @min(@as(usize, claimed_byte_start), source_body_text.len);
    const e_idx: usize = @min(@as(usize, claimed_byte_end), source_body_text.len);

    if (e_idx > s_idx) {
        const direct_window = source_body_text[s_idx..e_idx];
        if (std.mem.indexOf(u8, direct_window, passage_text)) |rel_offset| {
            const exact_start: u32 = @intCast(s_idx + rel_offset);
            const exact_end: u32 = @intCast(s_idx + rel_offset + passage_text.len);
            return .{
                .aligned = true,
                .verified_byte_start = exact_start,
                .verified_byte_end = exact_end,
            };
        }
    }

    if (std.mem.indexOf(u8, source_body_text, passage_text)) |found_idx| {
        return .{
            .aligned = true,
            .verified_byte_start = @intCast(found_idx),
            .verified_byte_end = @intCast(found_idx + passage_text.len),
        };
    }

    return .{ .aligned = false, .verified_byte_start = 0, .verified_byte_end = 0 };
}
