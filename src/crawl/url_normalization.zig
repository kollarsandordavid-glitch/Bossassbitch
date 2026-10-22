const std = @import("std");
const hashing = @import("../util/hashing.zig");

const TRACKING_PARAMS = [_][]const u8{
    "utm_source",
    "utm_medium",
    "utm_campaign",
    "utm_term",
    "utm_content",
    "utm_id",
    "fbclid",
    "gclid",
    "msclkid",
    "twclid",
    "mc_cid",
    "mc_eid",
    "sessionid",
    "session_id",
    "phpsessid",
    "jsessionid",
    "ref",
    "spm",
};

pub fn isTrackingParam(name: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(name, "utm_")) return true;
    for (TRACKING_PARAMS) |tp| {
        if (std.ascii.eqlIgnoreCase(name, tp)) return true;
    }
    return false;
}

pub fn normalizeUrl(allocator: std.mem.Allocator, raw_url: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_url, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidUrl;

    const no_frag = if (std.mem.indexOfScalar(u8, trimmed, '#')) |fidx|
        trimmed[0..fidx]
    else
        trimmed;

    const scheme_sep = std.mem.indexOf(u8, no_frag, "://") orelse return error.InvalidUrl;
    const raw_scheme = no_frag[0..scheme_sep];
    const after_scheme = no_frag[scheme_sep + 3 ..];

    var scheme_buf: [16]u8 = undefined;
    if (raw_scheme.len == 0 or raw_scheme.len > scheme_buf.len) return error.InvalidUrl;
    for (raw_scheme, 0..) |ch, i| {
        scheme_buf[i] = std.ascii.toLower(ch);
    }
    const scheme = scheme_buf[0..raw_scheme.len];

    var host_end = after_scheme.len;
    if (std.mem.indexOfAny(u8, after_scheme, "/?")) |idx| {
        host_end = idx;
    }
    const authority = after_scheme[0..host_end];
    const rest = after_scheme[host_end..];

    var host_slice = authority;
    var port_opt: ?u16 = null;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon_idx| {
        host_slice = authority[0..colon_idx];
        port_opt = std.fmt.parseInt(u16, authority[colon_idx + 1 ..], 10) catch null;
    }
    if (host_slice.len == 0) return error.InvalidUrl;

    var raw_path: []const u8 = "/";
    var raw_query: []const u8 = "";
    if (rest.len > 0) {
        if (std.mem.indexOfScalar(u8, rest, '?')) |q_idx| {
            raw_path = if (q_idx == 0) "/" else rest[0..q_idx];
            raw_query = rest[q_idx + 1 ..];
        } else {
            raw_path = rest;
        }
    }

    var segments = std.ArrayList([]const u8).init(allocator);
    defer segments.deinit();
    var seg_iter = std.mem.splitScalar(u8, raw_path, '/');
    while (seg_iter.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
            continue;
        }
        try segments.append(seg);
    }

    var kept_params = std.ArrayList([]const u8).init(allocator);
    defer kept_params.deinit();
    if (raw_query.len > 0) {
        var q_iter = std.mem.splitScalar(u8, raw_query, '&');
        while (q_iter.next()) |kv| {
            if (kv.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, kv, '=');
            const k = if (eq) |idx| kv[0..idx] else kv;
            if (!isTrackingParam(k)) {
                try kept_params.append(kv);
            }
        }
        std.mem.sort([]const u8, kept_params.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(scheme);
    try out.appendSlice("://");
    for (host_slice) |ch| {
        try out.append(std.ascii.toLower(ch));
    }

    if (port_opt) |p| {
        const is_default = (std.mem.eql(u8, scheme, "http") and p == 80) or
            (std.mem.eql(u8, scheme, "https") and p == 443);
        if (!is_default) {
            try out.writer().print(":{d}", .{p});
        }
    }

    if (segments.items.len == 0) {
        try out.append('/');
    } else {
        for (segments.items) |seg| {
            try out.append('/');
            try out.appendSlice(seg);
        }
    }

    if (kept_params.items.len > 0) {
        try out.append('?');
        for (kept_params.items, 0..) |param, idx| {
            if (idx > 0) try out.append('&');
            try out.appendSlice(param);
        }
    }

    return out.toOwnedSlice();
}

pub fn extractDomainHash(normalized_url: []const u8) u64 {
    const scheme_sep = std.mem.indexOf(u8, normalized_url, "://") orelse return hashing.domainHash(normalized_url);
    const after = normalized_url[scheme_sep + 3 ..];
    const end = std.mem.indexOfAny(u8, after, ":/?") orelse after.len;
    return hashing.domainHash(after[0..end]);
}
