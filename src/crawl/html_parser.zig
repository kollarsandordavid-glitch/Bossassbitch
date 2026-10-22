const std = @import("std");

pub const StructuralSpan = struct {
    byte_offset: u32,
    byte_length: u32,
    dom_depth: u16,
    heading_level: u8,
    element_tag: []u8,
    prominence_permille: u16,
    paragraph_index: u32,
    is_link_anchor: bool,

    pub fn deinit(self: *StructuralSpan, allocator: std.mem.Allocator) void {
        allocator.free(self.element_tag);
    }
};

pub const ExtractedLink = struct {
    target_url: []u8,
    anchor_text: []u8,
    rel_nofollow: bool,
    dom_depth: u16,

    pub fn deinit(self: *ExtractedLink, allocator: std.mem.Allocator) void {
        allocator.free(self.target_url);
        allocator.free(self.anchor_text);
    }
};

pub const ParsedHtmlDocument = struct {
    title: []u8,
    description: []u8,
    canonical_link: []u8,
    language: []u8,
    published_timestamp_ms: u64,
    main_text: []u8,
    spans: []StructuralSpan,
    links: []ExtractedLink,
    nested_table_depth_max: u16,
    malformed_recoveries: u32,

    pub fn deinit(self: *ParsedHtmlDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.canonical_link);
        allocator.free(self.language);
        allocator.free(self.main_text);
        for (self.spans) |*s| s.deinit(allocator);
        allocator.free(self.spans);
        for (self.links) |*l| l.deinit(allocator);
        allocator.free(self.links);
    }
};

pub const HtmlParser = struct {
    allocator: std.mem.Allocator,
    max_dom_depth: u16,
    max_nodes: u32,

    pub fn init(allocator: std.mem.Allocator, max_dom_depth: u16, max_nodes: u32) HtmlParser {
        return .{
            .allocator = allocator,
            .max_dom_depth = if (max_dom_depth == 0) 256 else max_dom_depth,
            .max_nodes = if (max_nodes == 0) 131072 else max_nodes,
        };
    }

    pub fn parse(self: *HtmlParser, html: []const u8) !ParsedHtmlDocument {
        var title_buf = std.ArrayList(u8).init(self.allocator);
        defer title_buf.deinit();
        var desc_buf = std.ArrayList(u8).init(self.allocator);
        defer desc_buf.deinit();
        var canon_buf = std.ArrayList(u8).init(self.allocator);
        defer canon_buf.deinit();
        var lang_buf = std.ArrayList(u8).init(self.allocator);
        defer lang_buf.deinit();
        var text_buf = std.ArrayList(u8).init(self.allocator);
        errdefer text_buf.deinit();

        var spans = std.ArrayList(StructuralSpan).init(self.allocator);
        errdefer {
            for (spans.items) |*s| s.deinit(self.allocator);
            spans.deinit();
        }
        var links = std.ArrayList(ExtractedLink).init(self.allocator);
        errdefer {
            for (links.items) |*l| l.deinit(self.allocator);
            links.deinit();
        }

        var depth: u16 = 0;
        var table_depth: u16 = 0;
        var max_table_depth: u16 = 0;
        var heading_level: u8 = 0;
        var in_script_or_style = false;
        var in_title = false;
        var in_anchor = false;
        var current_href: []const u8 = "";
        var current_nofollow = false;
        var anchor_text_start: usize = 0;
        var current_tag_name: []const u8 = "body";
        var current_prominence: u16 = 500;
        var paragraph_index: u32 = 0;
        var node_count: u32 = 0;
        var malformed_recoveries: u32 = 0;
        var published_ms: u64 = 0;

        var pos: usize = 0;
        while (pos < html.len and node_count < self.max_nodes) {
            if (html[pos] == '<') {
                if (pos + 4 <= html.len and std.mem.eql(u8, html[pos .. pos + 4], "<!--")) {
                    if (std.mem.indexOf(u8, html[pos + 4 ..], "-->")) |end_comment| {
                        pos += 4 + end_comment + 3;
                    } else {
                        malformed_recoveries += 1;
                        break;
                    }
                    continue;
                }
                const close_angle = std.mem.indexOfScalarPos(u8, html, pos + 1, '>') orelse {
                    malformed_recoveries += 1;
                    pos += 1;
                    continue;
                };
                node_count += 1;
                const raw_tag = std.mem.trim(u8, html[pos + 1 .. close_angle], " \t\r\n");
                pos = close_angle + 1;
                if (raw_tag.len == 0 or raw_tag[0] == '!') continue;

                const is_closing = raw_tag[0] == '/';
                const tag_body = if (is_closing) std.mem.trim(u8, raw_tag[1..], " \t\r\n") else raw_tag;
                const name_end = std.mem.indexOfAny(u8, tag_body, " \t\r\n/>") orelse tag_body.len;
                const tag_name = tag_body[0..name_end];
                const attrs = if (name_end < tag_body.len) tag_body[name_end..] else "";

                if (is_closing) {
                    if (depth > 0) depth -= 1;
                    if (std.ascii.eqlIgnoreCase(tag_name, "script") or
                        std.ascii.eqlIgnoreCase(tag_name, "style") or
                        std.ascii.eqlIgnoreCase(tag_name, "noscript"))
                    {
                        in_script_or_style = false;
                    } else if (std.ascii.eqlIgnoreCase(tag_name, "title")) {
                        in_title = false;
                    } else if (std.ascii.eqlIgnoreCase(tag_name, "table")) {
                        if (table_depth > 0) table_depth -= 1;
                    } else if (isHeadingTag(tag_name) != null) {
                        heading_level = 0;
                        current_prominence = 500;
                    } else if (std.ascii.eqlIgnoreCase(tag_name, "a") and in_anchor) {
                        in_anchor = false;
                        if (current_href.len > 0) {
                            const anchor_slice = if (anchor_text_start <= text_buf.items.len)
                                std.mem.trim(u8, text_buf.items[anchor_text_start..], " \t\r\n")
                            else
                                "";
                            try links.append(.{
                                .target_url = try self.allocator.dupe(u8, current_href),
                                .anchor_text = try self.allocator.dupe(u8, anchor_slice),
                                .rel_nofollow = current_nofollow,
                                .dom_depth = depth,
                            });
                        }
                        current_href = "";
                        current_nofollow = false;
                    } else if (std.ascii.eqlIgnoreCase(tag_name, "p") or
                        std.ascii.eqlIgnoreCase(tag_name, "article") or
                        std.ascii.eqlIgnoreCase(tag_name, "section") or
                        std.ascii.eqlIgnoreCase(tag_name, "tr"))
                    {
                        if (text_buf.items.len > 0 and text_buf.items[text_buf.items.len - 1] != '\n') {
                            try text_buf.append('\n');
                        }
                        paragraph_index += 1;
                    }
                } else {
                    const self_closing = std.mem.endsWith(u8, raw_tag, "/") or isVoidTag(tag_name);
                    if (!self_closing) {
                        if (depth < self.max_dom_depth) {
                            depth += 1;
                        } else {
                            malformed_recoveries += 1;
                        }
                    }
                    current_tag_name = tag_name;
                    current_prominence = computeVisualProminence(tag_name, attrs, depth);

                    if (std.ascii.eqlIgnoreCase(tag_name, "html")) {
                        if (extractAttr(attrs, "lang")) |lval| {
                            lang_buf.clearRetainingCapacity();
                            try lang_buf.appendSlice(lval);
                        }
                    } else if (std.ascii.eqlIgnoreCase(tag_name, "script") or
                        std.ascii.eqlIgnoreCase(tag_name, "style") or
                        std.ascii.eqlIgnoreCase(tag_name, "noscript"))
                    {
                        if (!self_closing) in_script_or_style = true;
                    } else if (std.ascii.eqlIgnoreCase(tag_name, "title")) {
                        if (!self_closing) in_title = true;
                    } else if (std.ascii.eqlIgnoreCase(tag_name, "table")) {
                        table_depth += 1;
                        if (table_depth > max_table_depth) max_table_depth = table_depth;
                    } else if (isHeadingTag(tag_name)) |hlvl| {
                        heading_level = hlvl;
                    } else if (std.ascii.eqlIgnoreCase(tag_name, "a")) {
                        if (extractAttr(attrs, "href")) |href| {
                            in_anchor = true;
                            current_href = href;
                            anchor_text_start = text_buf.items.len;
                            if (extractAttr(attrs, "rel")) |rel| {
                                current_nofollow = std.ascii.indexOfIgnoreCase(rel, "nofollow") != null;
                            }
                        }
                    } else if (std.ascii.eqlIgnoreCase(tag_name, "link")) {
                        if (extractAttr(attrs, "rel")) |rel| {
                            if (std.ascii.eqlIgnoreCase(rel, "canonical")) {
                                if (extractAttr(attrs, "href")) |href| {
                                    canon_buf.clearRetainingCapacity();
                                    try canon_buf.appendSlice(href);
                                }
                            }
                        }
                    } else if (std.ascii.eqlIgnoreCase(tag_name, "meta")) {
                        if (extractAttr(attrs, "name") orelse extractAttr(attrs, "property")) |mname| {
                            if (extractAttr(attrs, "content")) |mcontent| {
                                if (std.ascii.eqlIgnoreCase(mname, "description") or
                                    std.ascii.eqlIgnoreCase(mname, "og:description"))
                                {
                                    if (desc_buf.items.len == 0) {
                                        try desc_buf.appendSlice(mcontent);
                                    }
                                } else if (std.ascii.eqlIgnoreCase(mname, "article:published_time") or
                                    std.ascii.eqlIgnoreCase(mname, "pubdate"))
                                {
                                    published_ms = parseIsoYearToEpochMs(mcontent);
                                }
                            }
                        }
                    }
                }
            } else {
                const next_lt = std.mem.indexOfScalarPos(u8, html, pos, '<') orelse html.len;
                const raw_text = html[pos..next_lt];
                pos = next_lt;

                if (in_script_or_style) continue;
                if (in_title) {
                    try appendDecodedEntities(&title_buf, raw_text);
                    continue;
                }

                const start_offset: u32 = @intCast(text_buf.items.len);
                try appendDecodedEntities(&text_buf, raw_text);
                const end_offset: u32 = @intCast(text_buf.items.len);
                if (end_offset > start_offset) {
                    if (text_buf.items[end_offset - 1] != ' ' and text_buf.items[end_offset - 1] != '\n') {
                        try text_buf.append(' ');
                    }
                    try spans.append(.{
                        .byte_offset = start_offset,
                        .byte_length = end_offset - start_offset,
                        .dom_depth = depth,
                        .heading_level = heading_level,
                        .element_tag = try self.allocator.dupe(u8, current_tag_name),
                        .prominence_permille = current_prominence,
                        .paragraph_index = paragraph_index,
                        .is_link_anchor = in_anchor,
                    });
                }
            }
        }

        if (lang_buf.items.len == 0) {
            try lang_buf.appendSlice("en");
        }

        return .{
            .title = try title_buf.toOwnedSlice(),
            .description = try desc_buf.toOwnedSlice(),
            .canonical_link = try canon_buf.toOwnedSlice(),
            .language = try lang_buf.toOwnedSlice(),
            .published_timestamp_ms = published_ms,
            .main_text = try text_buf.toOwnedSlice(),
            .spans = try spans.toOwnedSlice(),
            .links = try links.toOwnedSlice(),
            .nested_table_depth_max = max_table_depth,
            .malformed_recoveries = malformed_recoveries,
        };
    }
};

fn isVoidTag(name: []const u8) bool {
    const voids = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" };
    for (voids) |v| {
        if (std.ascii.eqlIgnoreCase(name, v)) return true;
    }
    return false;
}

fn isHeadingTag(name: []const u8) ?u8 {
    if (name.len == 2 and (name[0] == 'h' or name[0] == 'H')) {
        if (name[1] >= '1' and name[1] <= '6') {
            return name[1] - '0';
        }
    }
    return null;
}

fn computeVisualProminence(tag_name: []const u8, attrs: []const u8, depth: u16) u16 {
    var score: i32 = 500;
    if (isHeadingTag(tag_name)) |lvl| {
        score = 950 - (@as(i32, lvl - 1) * 70);
    } else if (std.ascii.eqlIgnoreCase(tag_name, "main") or std.ascii.eqlIgnoreCase(tag_name, "article")) {
        score = 800;
    } else if (std.ascii.eqlIgnoreCase(tag_name, "footer") or std.ascii.eqlIgnoreCase(tag_name, "nav") or std.ascii.eqlIgnoreCase(tag_name, "aside")) {
        score = 200;
    }
    if (std.ascii.indexOfIgnoreCase(attrs, "display:none") != null or
        std.ascii.indexOfIgnoreCase(attrs, "visibility:hidden") != null)
    {
        score = 50;
    }
    score -= @as(i32, @intCast(@min(depth, 20))) * 8;
    return @intCast(std.math.clamp(score, 10, 1000));
}

fn extractAttr(attrs: []const u8, attr_name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        if (i >= attrs.len) break;
        const name_start = i;
        while (i < attrs.len and !std.ascii.isWhitespace(attrs[i]) and attrs[i] != '=') : (i += 1) {}
        const name = attrs[name_start..i];
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        if (i < attrs.len and attrs[i] == '=') {
            i += 1;
            while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
            if (i >= attrs.len) break;
            const quote = attrs[i];
            if (quote == '"' or quote == '\'') {
                i += 1;
                const val_start = i;
                while (i < attrs.len and attrs[i] != quote) : (i += 1) {}
                const val = attrs[val_start..i];
                if (i < attrs.len) i += 1;
                if (std.ascii.eqlIgnoreCase(name, attr_name)) return val;
            } else {
                const val_start = i;
                while (i < attrs.len and !std.ascii.isWhitespace(attrs[i]) and attrs[i] != '>') : (i += 1) {}
                const val = attrs[val_start..i];
                if (std.ascii.eqlIgnoreCase(name, attr_name)) return val;
            }
        }
    }
    return null;
}

fn appendDecodedEntities(out: *std.ArrayList(u8), raw: []const u8) !void {
    var i: usize = 0;
    var prev_space = false;
    while (i < raw.len) {
        const ch = raw[i];
        if (std.ascii.isWhitespace(ch)) {
            if (!prev_space and out.items.len > 0) {
                try out.append(' ');
                prev_space = true;
            }
            i += 1;
            continue;
        }
        prev_space = false;
        if (ch == '&') {
            if (std.mem.indexOfScalarPos(u8, raw, i + 1, ';')) |semi| {
                if (semi - i <= 10) {
                    const ent = raw[i + 1 .. semi];
                    if (std.mem.eql(u8, ent, "amp")) {
                        try out.append('&');
                        i = semi + 1;
                        continue;
                    } else if (std.mem.eql(u8, ent, "lt")) {
                        try out.append('<');
                        i = semi + 1;
                        continue;
                    } else if (std.mem.eql(u8, ent, "gt")) {
                        try out.append('>');
                        i = semi + 1;
                        continue;
                    } else if (std.mem.eql(u8, ent, "quot")) {
                        try out.append('"');
                        i = semi + 1;
                        continue;
                    } else if (std.mem.eql(u8, ent, "apos") or std.mem.eql(u8, ent, "#39")) {
                        try out.append('\'');
                        i = semi + 1;
                        continue;
                    } else if (std.mem.eql(u8, ent, "nbsp") or std.mem.eql(u8, ent, "#160")) {
                        try out.append(' ');
                        i = semi + 1;
                        continue;
                    }
                }
            }
        }
        try out.append(ch);
        i += 1;
    }
}

fn parseIsoYearToEpochMs(s: []const u8) u64 {
    if (s.len < 4) return 0;
    const year = std.fmt.parseInt(u64, s[0..4], 10) catch return 0;
    if (year < 1970 or year > 2100) return 0;
    return (year - 1970) * 365 * 86400 * 1000;
}
