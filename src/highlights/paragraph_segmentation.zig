const std = @import("std");

pub const SegmentedParagraph = struct {
    paragraph_id: u32,
    byte_start: u32,
    byte_end: u32,
    parent_heading: []u8,
    text_slice: []const u8,

    pub fn deinit(self: *SegmentedParagraph, allocator: std.mem.Allocator) void {
        allocator.free(self.parent_heading);
    }
};

pub fn segmentDocumentIntoParagraphs(
    allocator: std.mem.Allocator,
    doc_title: []const u8,
    body_text: []const u8,
) ![]SegmentedParagraph {
    var list = std.ArrayList(SegmentedParagraph).init(allocator);
    errdefer {
        for (list.items) |*p| p.deinit(allocator);
        list.deinit();
    }

    var current_heading: []const u8 = if (doc_title.len > 0) doc_title else "Overview";
    var start: usize = 0;
    var p_id: u32 = 0;

    var i: usize = 0;
    while (i <= body_text.len) : (i += 1) {
        const at_end = (i == body_text.len);
        const is_break = at_end or (body_text[i] == '\n') or
            ((body_text[i] == '.' or body_text[i] == '!' or body_text[i] == '?') and (i - start >= 180));

        if (is_break and i > start) {
            const raw_end = if (at_end) i else i + 1;
            const slice = std.mem.trim(u8, body_text[start..raw_end], " \t\r\n");
            if (slice.len > 0) {
                if (slice.len <= 80 and slice[slice.len - 1] != '.') {
                    current_heading = slice;
                }
                try list.append(.{
                    .paragraph_id = p_id,
                    .byte_start = @intCast(start),
                    .byte_end = @intCast(raw_end),
                    .parent_heading = try allocator.dupe(u8, current_heading),
                    .text_slice = slice,
                });
                p_id += 1;
            }
            start = raw_end;
        }
    }

    return list.toOwnedSlice();
}
