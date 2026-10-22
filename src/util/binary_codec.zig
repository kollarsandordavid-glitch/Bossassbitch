const std = @import("std");
const checksums = @import("checksums.zig");

pub const CodecError = error{
    UnexpectedEndOfBuffer,
    InvalidMagic,
    UnsupportedVersion,
    ChecksumFailure,
    Overflow,
    OutOfMemory,
};

pub const BinaryWriter = struct {
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) BinaryWriter {
        return .{ .buffer = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *BinaryWriter) void {
        self.buffer.deinit();
    }

    pub fn writeU8(self: *BinaryWriter, val: u8) !void {
        try self.buffer.append(val);
    }

    pub fn writeU16(self: *BinaryWriter, val: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, val, .little);
        try self.buffer.appendSlice(&bytes);
    }

    pub fn writeU32(self: *BinaryWriter, val: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, val, .little);
        try self.buffer.appendSlice(&bytes);
    }

    pub fn writeU64(self: *BinaryWriter, val: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, val, .little);
        try self.buffer.appendSlice(&bytes);
    }

    pub fn writeF32(self: *BinaryWriter, val: f32) !void {
        try self.writeU32(@bitCast(val));
    }

    pub fn writeBytes(self: *BinaryWriter, slice: []const u8) !void {
        if (slice.len > std.math.maxInt(u32)) return error.Overflow;
        try self.writeU32(@intCast(slice.len));
        try self.buffer.appendSlice(slice);
    }

    pub fn finalizeWithCrc(self: *BinaryWriter) ![]u8 {
        const crc = checksums.crc32(self.buffer.items);
        try self.writeU32(crc);
        return self.buffer.toOwnedSlice();
    }
};

pub const BinaryReader = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) BinaryReader {
        return .{ .data = data, .pos = 0 };
    }

    pub fn verifyTrailingCrc(data: []const u8) CodecError!BinaryReader {
        if (data.len < 4) return error.UnexpectedEndOfBuffer;
        const payload = data[0 .. data.len - 4];
        const expected = std.mem.readInt(u32, data[data.len - 4 ..][0..4], .little);
        if (!checksums.verifyCrc32(payload, expected)) return error.ChecksumFailure;
        return .{ .data = payload, .pos = 0 };
    }

    pub fn readU8(self: *BinaryReader) CodecError!u8 {
        if (self.pos + 1 > self.data.len) return error.UnexpectedEndOfBuffer;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn readU16(self: *BinaryReader) CodecError!u16 {
        if (self.pos + 2 > self.data.len) return error.UnexpectedEndOfBuffer;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    pub fn readU32(self: *BinaryReader) CodecError!u32 {
        if (self.pos + 4 > self.data.len) return error.UnexpectedEndOfBuffer;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn readU64(self: *BinaryReader) CodecError!u64 {
        if (self.pos + 8 > self.data.len) return error.UnexpectedEndOfBuffer;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    pub fn readF32(self: *BinaryReader) CodecError!f32 {
        const bits = try self.readU32();
        return @bitCast(bits);
    }

    pub fn readBytes(self: *BinaryReader) CodecError![]const u8 {
        const len: usize = @intCast(try self.readU32());
        if (self.pos + len > self.data.len) return error.UnexpectedEndOfBuffer;
        const slice = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }
};
