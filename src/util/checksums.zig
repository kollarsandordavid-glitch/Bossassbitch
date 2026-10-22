const std = @import("std");

pub fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

pub fn crc32Combine(prev_crc: u32, data: []const u8) u32 {
    var hasher = std.hash.Crc32.init();
    var seed_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &seed_bytes, prev_crc, .little);
    hasher.update(&seed_bytes);
    hasher.update(data);
    return hasher.final();
}

pub fn adler32(data: []const u8) u32 {
    const mod_adler: u32 = 65521;
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % mod_adler;
        b = (b + a) % mod_adler;
    }
    return (b << 16) | a;
}

pub fn verifyCrc32(data: []const u8, expected: u32) bool {
    return crc32(data) == expected;
}
