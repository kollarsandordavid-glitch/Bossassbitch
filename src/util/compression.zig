const std = @import("std");

pub const CompressionError = error{
    CorruptedStream,
    OutputBufferTooSmall,
    OutOfMemory,
};

pub fn encodeVarintU64(value: u64, out: []u8) CompressionError!usize {
    var v = value;
    var i: usize = 0;
    while (v >= 0x80) {
        if (i >= out.len) return error.OutputBufferTooSmall;
        out[i] = @as(u8, @truncate(v)) | 0x80;
        v >>= 7;
        i += 1;
    }
    if (i >= out.len) return error.OutputBufferTooSmall;
    out[i] = @as(u8, @truncate(v));
    return i + 1;
}

pub const DecodedVarint = struct {
    value: u64,
    bytes_read: usize,
};

pub fn decodeVarintU64(input: []const u8) CompressionError!DecodedVarint {
    var result: u64 = 0;
    var shift: u6 = 0;
    for (input, 0..) |byte, idx| {
        const low: u64 = byte & 0x7F;
        result |= (low << shift);
        if ((byte & 0x80) == 0) {
            return .{ .value = result, .bytes_read = idx + 1 };
        }
        if (shift >= 56) return error.CorruptedStream;
        shift += 7;
    }
    return error.CorruptedStream;
}

pub fn compressDeltaU64(allocator: std.mem.Allocator, sorted_ids: []const u64) CompressionError![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    var scratch: [10]u8 = undefined;
    const count_len = try encodeVarintU64(@intCast(sorted_ids.len), &scratch);
    try list.appendSlice(scratch[0..count_len]);

    var prev: u64 = 0;
    for (sorted_ids) |id| {
        const delta = if (id >= prev) id - prev else 0;
        prev = id;
        const n = try encodeVarintU64(delta, &scratch);
        try list.appendSlice(scratch[0..n]);
    }
    return list.toOwnedSlice();
}

pub fn decompressDeltaU64(allocator: std.mem.Allocator, compressed: []const u8) CompressionError![]u64 {
    if (compressed.len == 0) return allocator.alloc(u64, 0);
    const hdr = try decodeVarintU64(compressed);
    const count: usize = @intCast(hdr.value);
    var out = try allocator.alloc(u64, count);
    errdefer allocator.free(out);

    var offset = hdr.bytes_read;
    var prev: u64 = 0;
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        if (offset >= compressed.len) return error.CorruptedStream;
        const dec = try decodeVarintU64(compressed[offset..]);
        offset += dec.bytes_read;
        prev = std.math.add(u64, prev, dec.value) catch return error.CorruptedStream;
        out[idx] = prev;
    }
    return out;
}

pub fn compressByteBlock(allocator: std.mem.Allocator, input: []const u8) CompressionError![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var header: [10]u8 = undefined;
    const hlen = try encodeVarintU64(input.len, &header);
    try out.appendSlice(header[0..hlen]);

    var i: usize = 0;
    while (i < input.len) {
        var run_len: usize = 1;
        while (i + run_len < input.len and input[i + run_len] == input[i] and run_len < 127) {
            run_len += 1;
        }
        if (run_len >= 4) {
            try out.append(@as(u8, @intCast(run_len)) | 0x80);
            try out.append(input[i]);
            i += run_len;
        } else {
            const lit_start = i;
            var lit_len: usize = 0;
            while (i < input.len and lit_len < 127) {
                var ahead: usize = 1;
                while (i + ahead < input.len and input[i + ahead] == input[i] and ahead < 4) {
                    ahead += 1;
                }
                if (ahead >= 4) break;
                i += 1;
                lit_len += 1;
            }
            try out.append(@intCast(lit_len));
            try out.appendSlice(input[lit_start .. lit_start + lit_len]);
        }
    }
    return out.toOwnedSlice();
}

pub fn decompressByteBlock(allocator: std.mem.Allocator, compressed: []const u8) CompressionError![]u8 {
    if (compressed.len == 0) return error.CorruptedStream;
    const hdr = try decodeVarintU64(compressed);
    const expected_len: usize = @intCast(hdr.value);
    var out = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(out);

    var in_pos = hdr.bytes_read;
    var out_pos: usize = 0;
    while (in_pos < compressed.len and out_pos < expected_len) {
        const tag = compressed[in_pos];
        in_pos += 1;
        if ((tag & 0x80) != 0) {
            const run_len: usize = tag & 0x7F;
            if (in_pos >= compressed.len or out_pos + run_len > expected_len) return error.CorruptedStream;
            const byte = compressed[in_pos];
            in_pos += 1;
            @memset(out[out_pos .. out_pos + run_len], byte);
            out_pos += run_len;
        } else {
            const lit_len: usize = tag & 0x7F;
            if (in_pos + lit_len > compressed.len or out_pos + lit_len > expected_len) return error.CorruptedStream;
            @memcpy(out[out_pos .. out_pos + lit_len], compressed[in_pos .. in_pos + lit_len]);
            in_pos += lit_len;
            out_pos += lit_len;
        }
    }
    if (out_pos != expected_len) return error.CorruptedStream;
    return out;
}
