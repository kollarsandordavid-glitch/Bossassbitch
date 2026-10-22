const std = @import("std");
const lookup_tables = @import("lookup_tables.zig");

pub fn scoreCandidateNeon(
    lut: *const lookup_tables.QueryLookupTables,
    doc_packed: *const [32]u8,
) f32 {
    const Vec4f = @Vector(4, f32);
    var acc0: Vec4f = @splat(0.0);
    var acc1: Vec4f = @splat(0.0);

    inline for (0..4) |blk| {
        const base = blk * 8;
        const a = Vec4f{
            lut.byte_tables[base + 0][doc_packed[base + 0]],
            lut.byte_tables[base + 1][doc_packed[base + 1]],
            lut.byte_tables[base + 2][doc_packed[base + 2]],
            lut.byte_tables[base + 3][doc_packed[base + 3]],
        };
        const b = Vec4f{
            lut.byte_tables[base + 4][doc_packed[base + 4]],
            lut.byte_tables[base + 5][doc_packed[base + 5]],
            lut.byte_tables[base + 6][doc_packed[base + 6]],
            lut.byte_tables[base + 7][doc_packed[base + 7]],
        };
        acc0 += a;
        acc1 += b;
    }
    return @reduce(.Add, acc0 + acc1);
}

pub fn hammingPopcountNeon(
    query_packed: *const [32]u8,
    doc_packed: *const [32]u8,
) u32 {
    const Vec16u8 = @Vector(16, u8);
    const q0: Vec16u8 = query_packed[0..16].*;
    const d0: Vec16u8 = doc_packed[0..16].*;
    const q1: Vec16u8 = query_packed[16..32].*;
    const d1: Vec16u8 = doc_packed[16..32].*;
    const p0: @Vector(16, u16) = @intCast(@popCount(q0 ^ d0));
    const p1: @Vector(16, u16) = @intCast(@popCount(q1 ^ d1));
    return @intCast(@reduce(.Add, p0 + p1));
}
