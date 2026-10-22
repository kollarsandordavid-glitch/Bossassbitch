const std = @import("std");
const paragraph_segmentation = @import("paragraph_segmentation.zig");
const context_windows = @import("context_windows.zig");
const relevance_scoring = @import("relevance_scoring.zig");
const source_alignment = @import("source_alignment.zig");

pub const GroundedHighlight = struct {
    doc_id: u64,
    source_url: []u8,
    parent_heading: []u8,
    passage_text: []u8,
    byte_start: u32,
    byte_end: u32,
    score: f32,
    source_verified: bool,

    pub fn deinit(self: *GroundedHighlight, allocator: std.mem.Allocator) void {
        allocator.free(self.source_url);
        allocator.free(self.parent_heading);
        allocator.free(self.passage_text);
    }
};

pub const HighlightExtractor = struct {
    max_window_bytes: usize = 420,

    pub fn init() HighlightExtractor {
        return .{ .max_window_bytes = 420 };
    }

    pub fn extractHighlightsForDocument(
        self: HighlightExtractor,
        allocator: std.mem.Allocator,
        query_text: []const u8,
        doc_id: u64,
        source_url: []const u8,
        doc_title: []const u8,
        doc_body: []const u8,
        max_highlights: usize,
    ) ![]GroundedHighlight {
        const paragraphs = try paragraph_segmentation.segmentDocumentIntoParagraphs(allocator, doc_title, doc_body);
        defer {
            for (paragraphs) |*p| p.deinit(allocator);
            allocator.free(paragraphs);
        }

        const windows = try context_windows.buildSlidingContextWindows(
            allocator,
            paragraphs,
            doc_body,
            self.max_window_bytes,
        );
        defer {
            for (windows) |*w| w.deinit(allocator);
            allocator.free(windows);
        }

        var selected = std.ArrayList(GroundedHighlight).init(allocator);
        errdefer {
            for (selected.items) |*h| h.deinit(allocator);
            selected.deinit();
        }

        var selected_texts = std.ArrayList([]const u8).init(allocator);
        defer selected_texts.deinit();

        const target_count = @max(1, max_highlights);
        var round: usize = 0;
        while (round < target_count and round < windows.len) : (round += 1) {
            var best_idx: ?usize = null;
            var best_score: f32 = -1e9;

            for (windows, 0..) |win, w_idx| {
                const alignment = source_alignment.verifyPassageInSourceDocument(
                    doc_body,
                    win.byte_start,
                    win.byte_end,
                    win.window_text,
                );
                if (!alignment.aligned) continue;

                const comp = relevance_scoring.scorePassageAgainstQuery(
                    query_text,
                    win.window_text,
                    selected_texts.items,
                );
                if (comp.redundancy_penalty >= 0.9) continue;
                if (comp.combined_score > best_score) {
                    best_score = comp.combined_score;
                    best_idx = w_idx;
                }
            }

            if (best_idx) |b_idx| {
                const chosen = windows[b_idx];
                const alignment = source_alignment.verifyPassageInSourceDocument(
                    doc_body,
                    chosen.byte_start,
                    chosen.byte_end,
                    chosen.window_text,
                );
                const dup_text = try allocator.dupe(u8, chosen.window_text);
                errdefer allocator.free(dup_text);

                try selected.append(.{
                    .doc_id = doc_id,
                    .source_url = try allocator.dupe(u8, source_url),
                    .parent_heading = try allocator.dupe(u8, chosen.parent_heading),
                    .passage_text = dup_text,
                    .byte_start = alignment.verified_byte_start,
                    .byte_end = alignment.verified_byte_end,
                    .score = best_score,
                    .source_verified = alignment.aligned,
                });
                try selected_texts.append(dup_text);
            } else {
                break;
            }
        }

        return selected.toOwnedSlice();
    }
};
