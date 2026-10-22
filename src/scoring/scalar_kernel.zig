const std = @import("std");
const lookup_tables = @import("lookup_tables.zig");
const numeric_stability = @import("numeric_stability.zig");

pub fn scoreCandidateScalar(
    lut: *const lookup_tables.QueryLookupTables,
    doc_packed: *const [32]u8,
) f32 {
    var acc = numeric_stability.NeumaierAccumulator{};
    var i: usize = 0;
    while (i < 32) : (i += 4) {
        const s0 = lut.byte_tables[i][doc_packed[i]];
        const s1 = lut.byte_tables[i + 1][doc_packed[i + 1]];
        const s2 = lut.byte_tables[i + 2][doc_packed[i + 2]];
        const s3 = lut.byte_tables[i + 3][doc_packed[i + 3]];
        acc.add((s0 + s1) + (s2 + s3));
    }
    return acc.resultF32();
}

pub fn hammingPopcountScalar(
    query_packed: *const [32]u8,
    doc_packed: *const [32]u8,
) u32 {
    var dist: u32 = 0;
    var i: usize = 0;
    while (i < 32) : (i += 8) {
        const a = std.mem.readInt(u64, query_packed[i..][0..8], .little);
        const b = std.mem.readInt(u64, doc_packed[i..][0..8], .little);
        dist += @popCount(a ^ b);
    }
    return dist;
}
