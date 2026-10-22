const std = @import("std");
const errors = @import("../runtime/errors.zig");
const tls = @import("tls.zig");
const time_util = @import("../util/time.zig");

pub const FetchOutcomeKind = enum(u8) {
    success = 0,
    redirect = 1,
    client_error = 2,
    server_error = 3,
    access_denied_or_challenge = 4,
    network_error = 5,
};

pub const HttpResponse = struct {
    status_code: u16,
    outcome: FetchOutcomeKind,
    content_type: []u8,
    location_header: []u8,
    body: []u8,
    elapsed_ms: u64,

    pub fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.content_type);
        allocator.free(self.location_header);
        allocator.free(self.body);
    }
};

pub const ParsedUrl = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path_and_query: []const u8,
};

pub fn parseUrl(raw_url: []const u8) errors.EngineError!ParsedUrl {
    const scheme_sep = std.mem.indexOf(u8, raw_url, "://") orelse return error.InvalidInput;
    const scheme = raw_url[0..scheme_sep];
    const is_https = std.ascii.eqlIgnoreCase(scheme, "https");
    const is_http = std.ascii.eqlIgnoreCase(scheme, "http");
    if (!is_https and !is_http) return error.InvalidInput;

    const rest = raw_url[scheme_sep + 3 ..];
    if (rest.len == 0) return error.InvalidInput;

    const path_start = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..path_start];
    const path_and_query = if (path_start < rest.len) rest[path_start..] else "/";

    var host = authority;
    var port: u16 = if (is_https) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon_idx| {
        host = authority[0..colon_idx];
        port = std.fmt.parseInt(u16, authority[colon_idx + 1 ..], 10) catch return error.InvalidInput;
    }
    if (host.len == 0) return error.InvalidInput;

    return .{
        .scheme = scheme,
        .host = host,
        .port = port,
        .path_and_query = path_and_query,
    };
}

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    tls_ctx: tls.TlsContext,
    user_agent: []const u8,
    max_response_bytes: usize,
    timeout_ms: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        user_agent: []const u8,
        max_response_bytes: usize,
        timeout_ms: u64,
    ) HttpClient {
        return .{
            .allocator = allocator,
            .tls_ctx = tls.TlsContext.init(allocator),
            .user_agent = user_agent,
            .max_response_bytes = max_response_bytes,
            .timeout_ms = timeout_ms,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.tls_ctx.deinit();
    }

    pub fn get(self: *HttpClient, raw_url: []const u8, extra_header: ?[]const u8) !HttpResponse {
        _ = extra_header;
        return self.performRequest("GET", raw_url, null, null);
    }

    pub fn postJson(self: *HttpClient, raw_url: []const u8, json_body: []const u8) !HttpResponse {
        return self.performRequest("POST", raw_url, "application/json", json_body);
    }

    pub fn performRequest(
        self: *HttpClient,
        method: []const u8,
        raw_url: []const u8,
        content_type: ?[]const u8,
        payload: ?[]const u8,
    ) !HttpResponse {
        const sw = time_util.Stopwatch.start();
        const parsed = try parseUrl(raw_url);
        if (!tls.TlsContext.validateHostname(parsed.host)) {
            return error.InvalidInput;
        }

        var stream = try std.net.tcpConnectToHost(self.allocator, parsed.host, parsed.port);
        defer stream.close();

        var req_buf = std.ArrayList(u8).init(self.allocator);
        defer req_buf.deinit();
        const w = req_buf.writer();

        try w.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: {s}\r\nAccept: text/html,application/xhtml+xml,application/json;q=0.9\r\nConnection: close\r\n", .{
            method,
            parsed.path_and_query,
            parsed.host,
            self.user_agent,
        });
        if (content_type) |ct| {
            try w.print("Content-Type: {s}\r\n", .{ct});
        }
        if (payload) |body| {
            try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
            try w.writeAll(body);
        } else {
            try w.writeAll("\r\n");
        }

        try stream.writeAll(req_buf.items);

        var raw_resp = std.ArrayList(u8).init(self.allocator);
        defer raw_resp.deinit();

        var chunk: [8192]u8 = undefined;
        while (raw_resp.items.len < self.max_response_bytes) {
            const n = stream.read(&chunk) catch break;
            if (n == 0) break;
            try raw_resp.appendSlice(chunk[0..n]);
        }

        return try parseHttpResponse(self.allocator, raw_resp.items, sw.elapsedMillis());
    }
};

pub fn parseHttpResponse(allocator: std.mem.Allocator, raw: []const u8, elapsed_ms: u64) !HttpResponse {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.ProtocolViolation;
    const header_block = raw[0..header_end];
    const body_slice = raw[header_end + 4 ..];

    var lines = std.mem.splitSequence(u8, header_block, "\r\n");
    const status_line = lines.next() orelse return error.ProtocolViolation;
    var status_parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = status_parts.next() orelse return error.ProtocolViolation;
    const code_str = status_parts.next() orelse return error.ProtocolViolation;
    const status_code = std.fmt.parseInt(u16, code_str, 10) catch return error.ProtocolViolation;

    var content_type: []const u8 = "application/octet-stream";
    var location: []const u8 = "";
    var is_chunked = false;

    while (lines.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                content_type = val;
            } else if (std.ascii.eqlIgnoreCase(name, "location")) {
                location = val;
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                if (std.ascii.indexOfIgnoreCase(val, "chunked") != null) {
                    is_chunked = true;
                }
            }
        }
    }

    const decoded_body = if (is_chunked)
        try decodeChunkedBody(allocator, body_slice)
    else
        try allocator.dupe(u8, body_slice);

    const outcome: FetchOutcomeKind = if (status_code == 401 or status_code == 403 or status_code == 429 or status_code == 503)
        .access_denied_or_challenge
    else if (status_code >= 200 and status_code < 300)
        .success
    else if (status_code >= 300 and status_code < 400)
        .redirect
    else if (status_code >= 400 and status_code < 500)
        .client_error
    else
        .server_error;

    return .{
        .status_code = status_code,
        .outcome = outcome,
        .content_type = try allocator.dupe(u8, content_type),
        .location_header = try allocator.dupe(u8, location),
        .body = decoded_body,
        .elapsed_ms = elapsed_ms,
    };
}

fn decodeChunkedBody(allocator: std.mem.Allocator, raw_body: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var cursor: usize = 0;
    while (cursor < raw_body.len) {
        const line_end = std.mem.indexOfPos(u8, raw_body, cursor, "\r\n") orelse break;
        const size_str = std.mem.trim(u8, raw_body[cursor..line_end], " \t");
        const semi = std.mem.indexOfScalar(u8, size_str, ';') orelse size_str.len;
        const chunk_len = std.fmt.parseInt(usize, size_str[0..semi], 16) catch break;
        cursor = line_end + 2;
        if (chunk_len == 0) break;
        if (cursor + chunk_len > raw_body.len) break;
        try out.appendSlice(raw_body[cursor .. cursor + chunk_len]);
        cursor += chunk_len;
        if (cursor + 2 <= raw_body.len and std.mem.eql(u8, raw_body[cursor .. cursor + 2], "\r\n")) {
            cursor += 2;
        }
    }
    return out.toOwnedSlice();
}
