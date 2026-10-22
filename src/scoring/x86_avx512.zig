const std = @import("std");
const lookup_tables = @import("lookup_tables.zig");

pub fn scoreCandidateAvx512(
    lut: *const lookup_tables.QueryLookupTables,
    doc_packed: *const [32]u8,
) f32 {
    const Vec16f = @Vector(16, f32);
    const v0 = Vec16f{
        lut.byte_tables[0][doc_packed[0]],
        lut.byte_tables[1][doc_packed[1]],
        lut.byte_tables[2][doc_packed[2]],
        lut.byte_tables[3][doc_packed[3]],
        lut.byte_tables[4][doc_packed[4]],
        lut.byte_tables[5][doc_packed[5]],
        lut.byte_tables[6][doc_packed[6]],
        lut.byte_tables[7][doc_packed[7]],
        lut.byte_tables[8][doc_packed[8]],
        lut.byte_tables[9][doc_packed[9]],
        lut.byte_tables[10][doc_packed[10]],
        lut.byte_tables[11][doc_packed[11]],
        lut.byte_tables[12][doc_packed[12]],
        lut.byte_tables[13][doc_packed[13]],
        lut.byte_tables[14][doc_packed[14]],
        lut.byte_tables[15][doc_packed[15]],
    };
    const v1 = Vec16f{
        lut.byte_tables[16][doc_packed[16]],
        lut.byte_tables[17][doc_packed[17]],
        lut.byte_tables[18][doc_packed[18]],
        lut.byte_tables[19][doc_packed[19]],
        lut.byte_tables[20][doc_packed[20]],
        lut.byte_tables[21][doc_packed[21]],
        lut.byte_tables[22][doc_packed[22]],
        lut.byte_tables[23][doc_packed[23]],
        lut.byte_tables[24][doc_packed[24]],
        lut.byte_tables[25][doc_packed[25]],
        lut.byte_tables[26][doc_packed[26]],
        lut.byte_tables[27][doc_packed[27]],
        lut.byte_tables[28][doc_packed[28]],
        lut.byte_tables[29][doc_packed[29]],
        lut.byte_tables[30][doc_packed[30]],
        lut.byte_tables[31][doc_packed[31]],
    };
    return @reduce(.Add, v0 + v1);
}

pub fn hammingPopcountAvx512(
    query_packed: *const [32]u8,
    doc_packed: *const [32]u8,
) u32 {
    const Vec32u8 = @Vector(32, u8);
    const q: Vec32u8 = query_packed.*;
    const d: Vec32u8 = doc_packed.*;
    const xored = q ^ d;
    const pop8 = @popCount(xored);
    const pop16: @Vector(32, u16) = @intCast(pop8);
    return @intCast(@reduce(.Add, pop16));
}
