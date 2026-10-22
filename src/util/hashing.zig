const std = @import("std");

pub fn wyhash64(data: []const u8, seed: u64) u64 {
    return std.hash.Wyhash.hash(seed, data);
}

pub fn fnv1a64(data: []const u8) u64 {
    return std.hash.Fnv1a_64.hash(data);
}

pub fn sha256Digest(data: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return digest;
}

pub fn sha256Hex(data: []const u8) [64]u8 {
    const digest = sha256Digest(data);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn computeSimHash64(text: []const u8, shingle_width: usize) u64 {
    if (text.len == 0) return 0;
    const width = if (shingle_width == 0) 5 else shingle_width;
    var accum: [64]i32 = [_]i32{0} ** 64;

    if (text.len <= width) {
        const h = wyhash64(text, 0x517cc1b727220a95);
        var bit: u6 = 0;
        while (true) : (bit += 1) {
            if (((h >> bit) & 1) == 1) {
                accum[bit] += 1;
            } else {
                accum[bit] -= 1;
            }
            if (bit == 63) break;
        }
    } else {
        var i: usize = 0;
        while (i + width <= text.len) : (i += 1) {
            const window = text[i .. i + width];
            const h = wyhash64(window, 0x9e3779b97f4a7c15);
            var bit: u6 = 0;
            while (true) : (bit += 1) {
                if (((h >> bit) & 1) == 1) {
                    accum[bit] += 1;
                } else {
                    accum[bit] -= 1;
                }
                if (bit == 63) break;
            }
        }
    }

    var result: u64 = 0;
    var b: u6 = 0;
    while (true) : (b += 1) {
        if (accum[b] > 0) {
            result |= (@as(u64, 1) << b);
        }
        if (b == 63) break;
    }
    return result;
}

pub fn simHashHammingDistance(a: u64, b: u64) u32 {
    return @intCast(@popCount(a ^ b));
}

pub fn domainHash(host: []const u8) u64 {
    var buf: [256]u8 = undefined;
    const len = @min(host.len, buf.len);
    for (host[0..len], 0..) |ch, idx| {
        buf[idx] = std.ascii.toLower(ch);
    }
    return wyhash64(buf[0..len], 0x243f6a8885a308d3);
}
