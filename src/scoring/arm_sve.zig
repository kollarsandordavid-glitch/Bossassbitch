const std = @import("std");
const lookup_tables = @import("lookup_tables.zig");

pub fn scoreCandidateSve(
    lut: *const lookup_tables.QueryLookupTables,
    doc_packed: *const [32]u8,
) f32 {
    const Vec8f = @Vector(8, f32);
    var acc0: Vec8f = @splat(0.0);
    var acc1: Vec8f = @splat(0.0);

    inline for (0..2) |blk| {
        const base = blk * 16;
        const v0 = Vec8f{
            lut.byte_tables[base + 0][doc_packed[base + 0]],
            lut.byte_tables[base + 1][doc_packed[base + 1]],
            lut.byte_tables[base + 2][doc_packed[base + 2]],
            lut.byte_tables[base + 3][doc_packed[base + 3]],
            lut.byte_tables[base + 4][doc_packed[base + 4]],
            lut.byte_tables[base + 5][doc_packed[base + 5]],
            lut.byte_tables[base + 6][doc_packed[base + 6]],
            lut.byte_tables[base + 7][doc_packed[base + 7]],
        };
        const v1 = Vec8f{
            lut.byte_tables[base + 8][doc_packed[base + 8]],
            lut.byte_tables[base + 9][doc_packed[base + 9]],
            lut.byte_tables[base + 10][doc_packed[base + 10]],
            lut.byte_tables[base + 11][doc_packed[base + 11]],
            lut.byte_tables[base + 12][doc_packed[base + 12]],
            lut.byte_tables[base + 13][doc_packed[base + 13]],
            lut.byte_tables[base + 14][doc_packed[base + 14]],
            lut.byte_tables[base + 15][doc_packed[base + 15]],
        };
        acc0 += v0;
        acc1 += v1;
    }
    return @reduce(.Add, acc0 + acc1);
}

pub fn hammingPopcountSve(
    query_packed: *const [32]u8,
    doc_packed: *const [32]u8,
) u32 {
    const Vec32u8 = @Vector(32, u8);
    const q: Vec32u8 = query_packed.*;
    const d: Vec32u8 = doc_packed.*;
    const p: @Vector(32, u16) = @intCast(@popCount(q ^ d));
    return @intCast(@reduce(.Add, p));
}
