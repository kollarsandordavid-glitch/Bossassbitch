const std = @import("std");
const protocol = @import("protocol.zig");
const serialization = @import("serialization.zig");

pub const PeerEndpoint = struct {
    host: []const u8,
    port: u16,
};

pub const RpcTransport = struct {
    allocator: std.mem.Allocator,
    timeout_ms: u64,
    bytes_sent: std.atomic.Value(u64),
    bytes_received: std.atomic.Value(u64),
    failed_requests: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, timeout_ms: u64) RpcTransport {
        return .{
            .allocator = allocator,
            .timeout_ms = timeout_ms,
            .bytes_sent = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
            .failed_requests = std.atomic.Value(u64).init(0),
        };
    }

    pub fn sendFrameAndAwaitResponse(
        self: *RpcTransport,
        endpoint: PeerEndpoint,
        msg_type: protocol.RpcMessageType,
        request_id: u64,
        deadline_ms: u64,
        generation_id: u64,
        payload: []const u8,
    ) ![]u8 {
        const frame = try serialization.encodeRpcFrame(
            self.allocator,
            msg_type,
            request_id,
            deadline_ms,
            generation_id,
            payload,
        );
        defer self.allocator.free(frame);

        var stream = std.net.tcpConnectToHost(self.allocator, endpoint.host, endpoint.port) catch |err| {
            _ = self.failed_requests.fetchAdd(1, .monotonic);
            return err;
        };
        defer stream.close();

        stream.writeAll(frame) catch |err| {
            _ = self.failed_requests.fetchAdd(1, .monotonic);
            return err;
        };
        _ = self.bytes_sent.fetchAdd(frame.len, .monotonic);

        const hdr_size = @sizeOf(protocol.RpcFrameHeader);
        var hdr_buf: [hdr_size]u8 = undefined;
        const read_hdr = stream.readAll(&hdr_buf) catch |err| {
            _ = self.failed_requests.fetchAdd(1, .monotonic);
            return err;
        };
        if (read_hdr < hdr_size) {
            _ = self.failed_requests.fetchAdd(1, .monotonic);
            return error.EndOfStream;
        }
        var raw_hdr: protocol.RpcFrameHeader = undefined;
        @memcpy(std.mem.asBytes(&raw_hdr), &hdr_buf);
        const payload_len: usize = @intCast(std.mem.littleToNative(u32, raw_hdr.payload_len));

        var full_resp = try self.allocator.alloc(u8, hdr_size + payload_len);
        errdefer self.allocator.free(full_resp);
        @memcpy(full_resp[0..hdr_size], &hdr_buf);
        if (payload_len > 0) {
            const read_body = try stream.readAll(full_resp[hdr_size..]);
            if (read_body != payload_len) return error.EndOfStream;
        }
        _ = self.bytes_received.fetchAdd(full_resp.len, .monotonic);
        return full_resp;
    }
};
