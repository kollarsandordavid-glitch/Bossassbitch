const std = @import("std");
const paragraph_predictor = @import("paragraph_predictor.zig");

pub const ExtractedPassage = struct {
    passage_index: u32,
    byte_start: u32,
    byte_end: u32,
    text: []u8,
    relevance_score: f32,

    pub fn deinit(self: *ExtractedPassage, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const PassageExtractor = struct {
    predictor: paragraph_predictor.ParagraphPredictor,

    pub fn init() PassageExtractor {
        return .{
            .predictor = .{},
        };
    }

    pub fn extractQueryConditionedPassages(
        self: PassageExtractor,
        allocator: std.mem.Allocator,
        query_text: []const u8,
        body_text: []const u8,
        global_retained_embedding: *const [256]f32,
        max_passages: usize,
    ) ![]ExtractedPassage {
        const bounds = try self.predictor.predictParagraphs(allocator, body_text, global_retained_embedding);
        defer allocator.free(bounds);

        var candidates = std.ArrayList(ExtractedPassage).init(allocator);
        errdefer {
            for (candidates.items) |*c| c.deinit(allocator);
            candidates.deinit();
        }

        for (bounds, 0..) |b, idx| {
            const raw_slice = body_text[b.byte_start..b.byte_end];
            const trimmed = std.mem.trim(u8, raw_slice, " \t\r\n");
            if (trimmed.len == 0) continue;

            const lex_overlap = computeLexicalOverlap(query_text, trimmed);
            const score = b.coherence_score * 0.35 + lex_overlap * 0.65;
            try candidates.append(.{
                .passage_index = @intCast(idx),
                .byte_start = b.byte_start,
                .byte_end = b.byte_end,
                .text = try allocator.dupe(u8, trimmed),
                .relevance_score = score,
            });
        }

        std.mem.sort(ExtractedPassage, candidates.items, {}, struct {
            fn lessThan(_: void, a: ExtractedPassage, b: ExtractedPassage) bool {
                if (@abs(a.relevance_score - b.relevance_score) > 1e-6) {
                    return a.relevance_score > b.relevance_score;
                }
                return a.byte_start < b.byte_start;
            }
        }.lessThan);

        if (candidates.items.len > max_passages) {
            for (candidates.items[max_passages..]) |*extra| {
                extra.deinit(allocator);
            }
            candidates.shrinkRetainingCapacity(max_passages);
        }

        return candidates.toOwnedSlice();
    }
};

fn computeLexicalOverlap(query_text: []const u8, passage: []const u8) f32 {
    var q_tokens: u32 = 0;
    var matched: u32 = 0;
    var iter = std.mem.tokenizeAny(u8, query_text, " \t\r\n.,;:!?()[]{}");
    while (iter.next()) |q_tok| {
        if (q_tok.len < 2) continue;
        q_tokens += 1;
        if (std.ascii.indexOfIgnoreCase(passage, q_tok) != null) {
            matched += 1;
        }
    }
    if (q_tokens == 0) return 0.5;
    return @as(f32, @floatFromInt(matched)) / @as(f32, @floatFromInt(q_tokens));
}
