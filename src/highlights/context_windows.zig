const std = @import("std");
const paragraph_segmentation = @import("paragraph_segmentation.zig");

pub const SlidingContextWindow = struct {
    window_id: u32,
    start_paragraph_id: u32,
    end_paragraph_id: u32,
    byte_start: u32,
    byte_end: u32,
    parent_heading: []u8,
    window_text: []u8,

    pub fn deinit(self: *SlidingContextWindow, allocator: std.mem.Allocator) void {
        allocator.free(self.parent_heading);
        allocator.free(self.window_text);
    }
};

pub fn buildSlidingContextWindows(
    allocator: std.mem.Allocator,
    paragraphs: []const paragraph_segmentation.SegmentedParagraph,
    full_body_text: []const u8,
    max_window_bytes: usize,
) ![]SlidingContextWindow {
    var windows = std.ArrayList(SlidingContextWindow).init(allocator);
    errdefer {
        for (windows.items) |*w| w.deinit(allocator);
        windows.deinit();
    }

    for (paragraphs, 0..) |p, idx| {
        var end_idx = idx;
        var byte_end = p.byte_end;
        while (end_idx + 1 < paragraphs.len) {
            const next_p = paragraphs[end_idx + 1];
            if (next_p.byte_end - p.byte_start > max_window_bytes) break;
            end_idx += 1;
            byte_end = next_p.byte_end;
        }

        const safe_start = @min(@as(usize, p.byte_start), full_body_text.len);
        const safe_end = @min(@as(usize, byte_end), full_body_text.len);
        const raw_slice = std.mem.trim(u8, full_body_text[safe_start..safe_end], " \t\r\n");
        if (raw_slice.len == 0) continue;

        try windows.append(.{
            .window_id = @intCast(idx),
            .start_paragraph_id = p.paragraph_id,
            .end_paragraph_id = paragraphs[end_idx].paragraph_id,
            .byte_start = @intCast(safe_start),
            .byte_end = @intCast(safe_end),
            .parent_heading = try allocator.dupe(u8, p.parent_heading),
            .window_text = try allocator.dupe(u8, raw_slice),
        });
    }

    return windows.toOwnedSlice();
}
