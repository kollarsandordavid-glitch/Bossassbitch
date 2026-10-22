const std = @import("std");

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    OPTIONS,
    UNKNOWN,

    pub fn fromString(s: []const u8) HttpMethod {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        return .UNKNOWN;
    }
};

pub const IncomingHttpRequest = struct {
    method: HttpMethod,
    path: []const u8,
    query_string: []const u8,
    content_type: []const u8,
    body: []const u8,
};

pub const OutgoingHttpResponse = struct {
    status_code: u16,
    content_type: []const u8,
    body: []u8,

    pub fn deinit(self: *OutgoingHttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub const RequestHandlerFn = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    req: IncomingHttpRequest,
) anyerror!OutgoingHttpResponse;

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    bind_address: []const u8,
    port: u16,
    max_body_bytes: usize,
    handler_ctx: *anyopaque,
    handler_fn: RequestHandlerFn,
    running: std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        bind_address: []const u8,
        port: u16,
        max_body_bytes: usize,
        handler_ctx: *anyopaque,
        handler_fn: RequestHandlerFn,
    ) HttpServer {
        return .{
            .allocator = allocator,
            .bind_address = bind_address,
            .port = port,
            .max_body_bytes = max_body_bytes,
            .handler_ctx = handler_ctx,
            .handler_fn = handler_fn,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn stop(self: *HttpServer) void {
        self.running.store(false, .release);
    }

    pub fn listenAndServe(self: *HttpServer) !void {
        const addr = try std.net.Address.parseIp(self.bind_address, self.port);
        var server = try addr.listen(.{ .reuse_address = true });
        defer server.deinit();

        self.running.store(true, .release);
        while (self.running.load(.acquire)) {
            var conn = server.accept() catch continue;
            self.handleConnection(&conn);
        }
    }

    pub fn handleConnection(self: *HttpServer, conn: *std.net.Server.Connection) void {
        defer conn.stream.close();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var buf = std.ArrayList(u8).init(alloc);
        var temp: [8192]u8 = undefined;
        var header_end: ?usize = null;
        var expected_content_len: usize = 0;

        while (true) {
            const n = conn.stream.read(&temp) catch return;
            if (n == 0) break;
            if (buf.items.len + n > self.max_body_bytes + 65536) {
                writeStatusAndBody(conn.stream, 413, "application/json", "{\"error\":\"payload_too_large\"}");
                return;
            }
            buf.appendSlice(temp[0..n]) catch return;
            if (header_end == null) {
                if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |idx| {
                    header_end = idx;
                    expected_content_len = parseContentLength(buf.items[0..idx]);
                    if (expected_content_len > self.max_body_bytes) {
                        writeStatusAndBody(conn.stream, 413, "application/json", "{\"error\":\"payload_too_large\"}");
                        return;
                    }
                }
            }
            if (header_end) |hend| {
                const current_body_len = buf.items.len - (hend + 4);
                if (current_body_len >= expected_content_len) break;
            }
        }

        const hend = header_end orelse {
            writeStatusAndBody(conn.stream, 400, "application/json", "{\"error\":\"malformed_http_headers\"}");
            return;
        };

        const req = parseRequestSlice(buf.items[0..hend], buf.items[hend + 4 ..], expected_content_len) catch {
            writeStatusAndBody(conn.stream, 400, "application/json", "{\"error\":\"malformed_http_request\"}");
            return;
        };

        var resp = self.handler_fn(self.handler_ctx, alloc, req) catch {
            writeStatusAndBody(conn.stream, 500, "application/json", "{\"error\":\"internal_execution_error\"}");
            return;
        };
        defer resp.deinit(alloc);
        writeStatusAndBody(conn.stream, resp.status_code, resp.content_type, resp.body);
    }
};

fn parseContentLength(header_bytes: []const u8) usize {
    var lines = std.mem.splitSequence(u8, header_bytes, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            return std.fmt.parseInt(usize, val, 10) catch 0;
        }
    }
    return 0;
}

fn parseRequestSlice(header_bytes: []const u8, body_bytes: []const u8, content_len: usize) !IncomingHttpRequest {
    var lines = std.mem.splitSequence(u8, header_bytes, "\r\n");
    const req_line = lines.next() orelse return error.MalformedRequest;
    var parts = std.mem.tokenizeScalar(u8, req_line, ' ');
    const method_str = parts.next() orelse return error.MalformedRequest;
    const raw_target = parts.next() orelse return error.MalformedRequest;

    var path = raw_target;
    var query_string: []const u8 = "";
    if (std.mem.indexOfScalar(u8, raw_target, '?')) |q_idx| {
        path = raw_target[0..q_idx];
        query_string = raw_target[q_idx + 1 ..];
    }

    var content_type: []const u8 = "application/json";
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            content_type = val;
        }
    }

    const actual_len = @min(body_bytes.len, content_len);
    return .{
        .method = HttpMethod.fromString(method_str),
        .path = path,
        .query_string = query_string,
        .content_type = content_type,
        .body = body_bytes[0..actual_len],
    };
}

fn statusPhrase(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "OK",
    };
}

fn writeStatusAndBody(stream: std.net.Stream, status_code: u16, content_type: []const u8, body: []const u8) void {
    var hdr_buf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status_code, statusPhrase(status_code), content_type, body.len },
    ) catch return;
    stream.writeAll(hdr) catch return;
    stream.writeAll(body) catch return;
}
