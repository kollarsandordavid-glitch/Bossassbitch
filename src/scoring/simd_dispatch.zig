const std = @import("std");
const platform = @import("../util/platform.zig");
const lookup_tables = @import("lookup_tables.zig");
const scalar_kernel = @import("scalar_kernel.zig");
const x86_avx2 = @import("x86_avx2.zig");
const x86_avx512 = @import("x86_avx512.zig");
const arm_neon = @import("arm_neon.zig");
const arm_sve = @import("arm_sve.zig");

pub const ScoreKernelFn = *const fn (
    lut: *const lookup_tables.QueryLookupTables,
    doc_packed: *const [32]u8,
) f32;

pub const HammingKernelFn = *const fn (
    query_packed: *const [32]u8,
    doc_packed: *const [32]u8,
) u32;

pub const SimdDispatcher = struct {
    backend: platform.SimdBackend,
    score_fn: ScoreKernelFn,
    hamming_fn: HammingKernelFn,

    pub fn initForTopology(topo: platform.HardwareTopology) SimdDispatcher {
        return switch (topo.preferred_simd) {
            .x86_avx512 => .{
                .backend = .x86_avx512,
                .score_fn = x86_avx512.scoreCandidateAvx512,
                .hamming_fn = x86_avx512.hammingPopcountAvx512,
            },
            .x86_avx2 => .{
                .backend = .x86_avx2,
                .score_fn = x86_avx2.scoreCandidateAvx2,
                .hamming_fn = x86_avx2.hammingPopcountAvx2,
            },
            .arm_sve => .{
                .backend = .arm_sve,
                .score_fn = arm_sve.scoreCandidateSve,
                .hamming_fn = arm_sve.hammingPopcountSve,
            },
            .arm_neon => .{
                .backend = .arm_neon,
                .score_fn = arm_neon.scoreCandidateNeon,
                .hamming_fn = arm_neon.hammingPopcountNeon,
            },
            .scalar => .{
                .backend = .scalar,
                .score_fn = scalar_kernel.scoreCandidateScalar,
                .hamming_fn = scalar_kernel.hammingPopcountScalar,
            },
        };
    }

    pub fn initAuto() SimdDispatcher {
        const topo = platform.detectTopology();
        return initForTopology(topo);
    }

    pub inline fn score(
        self: SimdDispatcher,
        lut: *const lookup_tables.QueryLookupTables,
        doc_packed: *const [32]u8,
    ) f32 {
        return self.score_fn(lut, doc_packed);
    }

    pub inline fn hamming(
        self: SimdDispatcher,
        query_packed: *const [32]u8,
        doc_packed: *const [32]u8,
    ) u32 {
        return self.hamming_fn(query_packed, doc_packed);
    }
};
