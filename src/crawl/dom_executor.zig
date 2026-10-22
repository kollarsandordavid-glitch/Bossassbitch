const std = @import("std");

pub const DomExecutionOutcome = struct {
    augmented_html: []u8,
    discovered_spa_routes: [][]u8,
    executed_statements: u32,
    extracted_state_nodes: u32,

    pub fn deinit(self: *DomExecutionOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.augmented_html);
        for (self.discovered_spa_routes) |l| allocator.free(l);
        allocator.free(self.discovered_spa_routes);
    }
};

pub const DomExecutor = struct {
    allocator: std.mem.Allocator,
    max_content_bytes: usize,

    pub fn init(allocator: std.mem.Allocator, max_content_bytes: usize) DomExecutor {
        return .{
            .allocator = allocator,
            .max_content_bytes = max_content_bytes,
        };
    }

    pub fn executeDomScriptsAndState(self: *DomExecutor, raw_html: []const u8) !DomExecutionOutcome {
        var extra_markup = std.ArrayList(u8).init(self.allocator);
        defer extra_markup.deinit();
        var links = std.ArrayList([]u8).init(self.allocator);
        errdefer {
            for (links.items) |l| self.allocator.free(l);
            links.deinit();
        }

        var statements_run: u32 = 0;
        var state_nodes: u32 = 0;
        var cursor: usize = 0;

        while (cursor < raw_html.len and statements_run < 8192) {
            const script_start = indexOfCaseInsensitivePos(raw_html, cursor, "<script") orelse break;
            const open_end = std.mem.indexOfScalarPos(u8, raw_html, script_start, '>') orelse break;
            const open_tag = raw_html[script_start..open_end];
            const script_close = indexOfCaseInsensitivePos(raw_html, open_end + 1, "</script>") orelse break;
            const script_body = raw_html[open_end + 1 .. script_close];
            cursor = script_close + 9;

            if (indexOfCaseInsensitivePos(open_tag, 0, "application/json") != null or
                indexOfCaseInsensitivePos(open_tag, 0, "__NEXT_DATA__") != null or
                indexOfCaseInsensitivePos(open_tag, 0, "application/ld+json") != null)
            {
                try self.hydrateJsonStatePayload(script_body, &extra_markup, &links, &state_nodes);
            } else {
                try self.evaluateScriptBody(script_body, &extra_markup, &links, &statements_run);
            }
        }

        var combined = std.ArrayList(u8).init(self.allocator);
        errdefer combined.deinit();
        try combined.appendSlice(raw_html[0..@min(raw_html.len, self.max_content_bytes)]);
        if (extra_markup.items.len > 0) {
            try combined.appendSlice("\n<section data-hydrated=\"dom-executor\">");
            try combined.appendSlice(extra_markup.items);
            try combined.appendSlice("</section>");
        }

        return .{
            .augmented_html = try combined.toOwnedSlice(),
            .discovered_spa_routes = try links.toOwnedSlice(),
            .executed_statements = statements_run,
            .extracted_state_nodes = state_nodes,
        };
    }

    fn hydrateJsonStatePayload(
        self: *DomExecutor,
        json_text: []const u8,
        extra_markup: *std.ArrayList(u8),
        links: *std.ArrayList([]u8),
        state_nodes: *u32,
    ) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_text, .{}) catch {
            var literal_steps: u32 = 0;
            try self.evaluateScriptBody(json_text, extra_markup, links, &literal_steps);
            return;
        };
        defer parsed.deinit();
        try self.traverseJsonValue(parsed.value, extra_markup, links, state_nodes, 0);
    }

    fn traverseJsonValue(
        self: *DomExecutor,
        val: std.json.Value,
        extra_markup: *std.ArrayList(u8),
        links: *std.ArrayList([]u8),
        state_nodes: *u32,
        depth: u32,
    ) !void {
        if (depth > 24 or state_nodes.* >= 4096) return;
        state_nodes.* += 1;
        switch (val) {
            .string => |s| {
                if (std.mem.startsWith(u8, s, "http://") or
                    std.mem.startsWith(u8, s, "https://") or
                    (s.len > 2 and s[0] == '/' and s[1] != '/'))
                {
                    if (s.len < 512 and std.mem.indexOfAny(u8, s, " \t\r\n<>") == null) {
                        try links.append(try self.allocator.dupe(u8, s));
                    }
                } else if (s.len >= 24 and looksLikeNaturalProse(s)) {
                    try extra_markup.appendSlice("<p>");
                    try extra_markup.appendSlice(s);
                    try extra_markup.appendSlice("</p>");
                }
            },
            .array => |arr| {
                for (arr.items) |item| {
                    try self.traverseJsonValue(item, extra_markup, links, state_nodes, depth + 1);
                }
            },
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |kv| {
                    try self.traverseJsonValue(kv.value_ptr.*, extra_markup, links, state_nodes, depth + 1);
                }
            },
            else => {},
        }
    }

    fn evaluateScriptBody(
        self: *DomExecutor,
        script: []const u8,
        extra_markup: *std.ArrayList(u8),
        links: *std.ArrayList([]u8),
        statements_run: *u32,
    ) !void {
        var pos: usize = 0;
        while (pos < script.len and statements_run.* < 8192) {
            const quote_pos = std.mem.indexOfAnyPos(u8, script, pos, "\"'") orelse break;
            const quote_char = script[quote_pos];
            const end_quote = std.mem.indexOfScalarPos(u8, script, quote_pos + 1, quote_char) orelse break;
            const literal = script[quote_pos + 1 .. end_quote];
            pos = end_quote + 1;
            statements_run.* += 1;

            if (std.mem.startsWith(u8, literal, "http://") or
                std.mem.startsWith(u8, literal, "https://") or
                (literal.len > 2 and literal[0] == '/' and literal[1] != '/'))
            {
                if (literal.len < 512 and std.mem.indexOfAny(u8, literal, " \t\r\n<>") == null) {
                    try links.append(try self.allocator.dupe(u8, literal));
                }
            } else if (literal.len >= 24 and looksLikeNaturalProse(literal)) {
                try extra_markup.appendSlice("<p>");
                try extra_markup.appendSlice(literal);
                try extra_markup.appendSlice("</p>");
            }
        }
    }
};

fn looksLikeNaturalProse(s: []const u8) bool {
    var spaces: usize = 0;
    var alpha: usize = 0;
    for (s) |ch| {
        if (ch == ' ') spaces += 1;
        if (std.ascii.isAlphabetic(ch)) alpha += 1;
        if (ch == '{' or ch == '}' or ch == ';') return false;
    }
    return spaces >= 3 and alpha * 2 >= s.len;
}

fn indexOfCaseInsensitivePos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or start + needle.len > haystack.len) return null;
    var i: usize = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}
