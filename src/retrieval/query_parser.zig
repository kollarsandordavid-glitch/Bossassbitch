const std = @import("std");
const hashing = @import("../util/hashing.zig");

pub const ParsedQueryTerm = struct {
    surface: []u8,
    term_hash: u64,
    is_exact_phrase_member: bool,
    is_code_identifier: bool,

    pub fn deinit(self: *ParsedQueryTerm, allocator: std.mem.Allocator) void {
        allocator.free(self.surface);
    }
};

pub const ParsedQuery = struct {
    raw_query: []u8,
    terms: []ParsedQueryTerm,
    has_quotes: bool,
    has_code_syntax: bool,
    has_research_intent: bool,
    has_executive_intent: bool,

    pub fn deinit(self: *ParsedQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.raw_query);
        for (self.terms) |*t| t.deinit(allocator);
        allocator.free(self.terms);
    }
};

pub fn parseQuery(allocator: std.mem.Allocator, query_text: []const u8) !ParsedQuery {
    const trimmed = std.mem.trim(u8, query_text, " \t\r\n");
    var terms = std.ArrayList(ParsedQueryTerm).init(allocator);
    errdefer {
        for (terms.items) |*t| t.deinit(allocator);
        terms.deinit();
    }

    const has_quotes = std.mem.indexOfScalar(u8, trimmed, '"') != null;
    const has_code = std.mem.indexOfAny(u8, trimmed, "{}();_:") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "fn ") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "struct ") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "simd") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "avx") != null;

    const has_research = std.ascii.indexOfIgnoreCase(trimmed, "arxiv") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "paper") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "study") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "compare") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "theorem") != null;

    const has_exec = std.ascii.indexOfIgnoreCase(trimmed, "ceo") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "founder") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "executive") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "vp ") != null;

    var in_quote = false;
    var iter = std.mem.tokenizeAny(u8, trimmed, " \t\r\n,.;!?()[]{}");
    while (iter.next()) |raw_tok| {
        if (std.mem.indexOfScalar(u8, raw_tok, '"') != null) {
            in_quote = !in_quote;
        }
        const clean = std.mem.trim(u8, raw_tok, "\"'");
        if (clean.len == 0) continue;

        var lower_buf: [64]u8 = undefined;
        const l_len = @min(clean.len, lower_buf.len);
        var has_underscore_or_camel = false;
        for (clean[0..l_len], 0..) |ch, idx| {
            if (ch == '_' or (idx > 0 and std.ascii.isUpper(ch))) {
                has_underscore_or_camel = true;
            }
            lower_buf[idx] = std.ascii.toLower(ch);
        }

        const thash = hashing.wyhash64(lower_buf[0..l_len], 0x7265747269657665);
        try terms.append(.{
            .surface = try allocator.dupe(u8, lower_buf[0..l_len]),
            .term_hash = thash,
            .is_exact_phrase_member = in_quote,
            .is_code_identifier = has_underscore_or_camel,
        });
    }

    return .{
        .raw_query = try allocator.dupe(u8, trimmed),
        .terms = try terms.toOwnedSlice(),
        .has_quotes = has_quotes,
        .has_code_syntax = has_code,
        .has_research_intent = has_research,
        .has_executive_intent = has_exec,
    };
}
