const std = @import("std");
const protocol = @import("protocol.zig");
const checksums = @import("../util/checksums.zig");

pub const WireError = error{
    InvalidMagic,
    UnsupportedVersion,
    FrameTooShort,
    ChecksumMismatch,
    InvalidMessageType,
    OutOfMemory,
};

pub fn encodeRpcFrame(
    allocator: std.mem.Allocator,
    msg_type: protocol.RpcMessageType,
    request_id: u64,
    deadline_ms: u64,
    generation_id: u64,
    payload: []const u8,
) WireError![]u8 {
    const hdr_size = @sizeOf(protocol.RpcFrameHeader);
    var buf = try allocator.alloc(u8, hdr_size + payload.len);
    const crc = checksums.crc32(payload);
    const hdr = protocol.RpcFrameHeader{
        .magic = std.mem.nativeToLittle(u32, protocol.RPC_MAGIC),
        .version = std.mem.nativeToLittle(u16, protocol.RPC_VERSION),
        .msg_type = std.mem.nativeToLittle(u16, @intFromEnum(msg_type)),
        .request_id = std.mem.nativeToLittle(u64, request_id),
        .deadline_ms = std.mem.nativeToLittle(u64, deadline_ms),
        .generation_id = std.mem.nativeToLittle(u64, generation_id),
        .payload_len = std.mem.nativeToLittle(u32, @intCast(payload.len)),
        .crc32 = std.mem.nativeToLittle(u32, crc),
    };
    @memcpy(buf[0..hdr_size], std.mem.asBytes(&hdr));
    if (payload.len > 0) {
        @memcpy(buf[hdr_size..], payload);
    }
    return buf;
}

pub const DecodedRpcFrame = struct {
    msg_type: protocol.RpcMessageType,
    request_id: u64,
    deadline_ms: u64,
    generation_id: u64,
    payload: []const u8,
};

pub fn decodeRpcFrame(frame_bytes: []const u8) WireError!DecodedRpcFrame {
    const hdr_size = @sizeOf(protocol.RpcFrameHeader);
    if (frame_bytes.len < hdr_size) return error.FrameTooShort;
    var raw: protocol.RpcFrameHeader = undefined;
    @memcpy(std.mem.asBytes(&raw), frame_bytes[0..hdr_size]);

    const magic = std.mem.littleToNative(u32, raw.magic);
    const version = std.mem.littleToNative(u16, raw.version);
    const msg_raw = std.mem.littleToNative(u16, raw.msg_type);
    const payload_len = std.mem.littleToNative(u32, raw.payload_len);
    const expected_crc = std.mem.littleToNative(u32, raw.crc32);

    if (magic != protocol.RPC_MAGIC) return error.InvalidMagic;
    if (version != protocol.RPC_VERSION) return error.UnsupportedVersion;
    if (frame_bytes.len < hdr_size + payload_len) return error.FrameTooShort;

    const payload = frame_bytes[hdr_size .. hdr_size + payload_len];
    if (!checksums.verifyCrc32(payload, expected_crc)) return error.ChecksumMismatch;

    const msg_type = std.meta.intToEnum(protocol.RpcMessageType, msg_raw) catch return error.InvalidMessageType;
    return .{
        .msg_type = msg_type,
        .request_id = std.mem.littleToNative(u64, raw.request_id),
        .deadline_ms = std.mem.littleToNative(u64, raw.deadline_ms),
        .generation_id = std.mem.littleToNative(u64, raw.generation_id),
        .payload = payload,
    };
}

pub fn encodeCandidateBatch(allocator: std.mem.Allocator, candidates: []const protocol.ShardCandidateRecord) ![]u8 {
    const rec_size = @sizeOf(protocol.ShardCandidateRecord);
    var out = try allocator.alloc(u8, 4 + candidates.len * rec_size);
    std.mem.writeInt(u32, out[0..4], @intCast(candidates.len), .little);
    for (candidates, 0..) |cand, i| {
        const start = 4 + i * rec_size;
        @memcpy(out[start .. start + rec_size], std.mem.asBytes(&cand));
    }
    return out;
}

pub fn decodeCandidateBatch(allocator: std.mem.Allocator, bytes: []const u8) ![]protocol.ShardCandidateRecord {
    if (bytes.len < 4) return error.FrameTooShort;
    const count: usize = @intCast(std.mem.readInt(u32, bytes[0..4], .little));
    const rec_size = @sizeOf(protocol.ShardCandidateRecord);
    if (bytes.len < 4 + count * rec_size) return error.FrameTooShort;
    var out = try allocator.alloc(protocol.ShardCandidateRecord, count);
    for (0..count) |i| {
        const start = 4 + i * rec_size;
        @memcpy(std.mem.asBytes(&out[i]), bytes[start .. start + rec_size]);
    }
    return out;
}
