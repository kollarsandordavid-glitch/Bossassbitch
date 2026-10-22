const std = @import("std");
const lookup_tables = @import("lookup_tables.zig");

pub fn scoreCandidateAvx2(
    lut: *const lookup_tables.QueryLookupTables,
    doc_packed: *const [32]u8,
) f32 {
    const Vec8f = @Vector(8, f32);
    var v_acc0: Vec8f = @splat(0.0);
    var v_acc1: Vec8f = @splat(0.0);

    inline for (0..2) |blk| {
        const base = blk * 16;
        const low_vec = Vec8f{
            lut.byte_tables[base + 0][doc_packed[base + 0]],
            lut.byte_tables[base + 1][doc_packed[base + 1]],
            lut.byte_tables[base + 2][doc_packed[base + 2]],
            lut.byte_tables[base + 3][doc_packed[base + 3]],
            lut.byte_tables[base + 4][doc_packed[base + 4]],
            lut.byte_tables[base + 5][doc_packed[base + 5]],
            lut.byte_tables[base + 6][doc_packed[base + 6]],
            lut.byte_tables[base + 7][doc_packed[base + 7]],
        };
        const high_vec = Vec8f{
            lut.byte_tables[base + 8][doc_packed[base + 8]],
            lut.byte_tables[base + 9][doc_packed[base + 9]],
            lut.byte_tables[base + 10][doc_packed[base + 10]],
            lut.byte_tables[base + 11][doc_packed[base + 11]],
            lut.byte_tables[base + 12][doc_packed[base + 12]],
            lut.byte_tables[base + 13][doc_packed[base + 13]],
            lut.byte_tables[base + 14][doc_packed[base + 14]],
            lut.byte_tables[base + 15][doc_packed[base + 15]],
        };
        v_acc0 += low_vec;
        v_acc1 += high_vec;
    }

    const combined = v_acc0 + v_acc1;
    return @reduce(.Add, combined);
}

pub fn hammingPopcountAvx2(
    query_packed: *const [32]u8,
    doc_packed: *const [32]u8,
) u32 {
    const Vec4u64 = @Vector(4, u64);
    const q: Vec4u64 = @bitCast(query_packed.*);
    const d: Vec4u64 = @bitCast(doc_packed.*);
    const xored = q ^ d;
    const pop = @popCount(xored);
    const pop_u32: @Vector(4, u32) = @intCast(pop);
    return @reduce(.Add, pop_u32);
}
