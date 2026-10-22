const std = @import("std");
const lookup_tables = @import("lookup_tables.zig");
const simd_dispatch = @import("simd_dispatch.zig");
const norm_compensation = @import("norm_compensation.zig");
const numeric_stability = @import("numeric_stability.zig");
const time_util = @import("../util/time.zig");

pub const AlignedCandidateScanRecord = extern struct {
    packed_binary: [32]u8 align(64),
    doc_id: u64,
    original_norm: f32,
    centroid_id: u32,
    published_at_ms: u64,
    domain_hash32: u32,
    quality_permille: u16,
    flags: u16,
};

comptime {
    if (@sizeOf(AlignedCandidateScanRecord) != 64) {
        @compileError("AlignedCandidateScanRecord must be exactly 64 bytes (1 cache line)");
    }
}

pub const ScoredCandidate = struct {
    doc_id: u64,
    centroid_id: u32,
    raw_binary_score: f32,
    compensated_score: f32,
    published_at_ms: u64,
    quality_permille: u16,
};

pub const ScanTelemetry = struct {
    candidates_scanned: u64,
    candidates_passed_filter: u64,
    elapsed_nanos: u64,
    throughput_candidates_per_sec: u64,
    bytes_streamed: u64,
};

pub const CandidateScanner = struct {
    dispatcher: simd_dispatch.SimdDispatcher,
    norm_params: norm_compensation.NormCompensationParams,
    total_scanned: std.atomic.Value(u64),
    total_nanos: std.atomic.Value(u64),

    pub fn init() CandidateScanner {
        return .{
            .dispatcher = simd_dispatch.SimdDispatcher.initAuto(),
            .norm_params = .{},
            .total_scanned = std.atomic.Value(u64).init(0),
            .total_nanos = std.atomic.Value(u64).init(0),
        };
    }

    pub fn scanBlockTopK(
        self: *CandidateScanner,
        allocator: std.mem.Allocator,
        lut: *const lookup_tables.QueryLookupTables,
        records: []const AlignedCandidateScanRecord,
        deleted_bitset: ?*const std.DynamicBitSetUnmanaged,
        min_quality_permille: u16,
        min_published_ms: u64,
        max_published_ms: u64,
        top_k: usize,
    ) !struct { results: []ScoredCandidate, telemetry: ScanTelemetry } {
        const sw = time_util.Stopwatch.start();
        var heap = std.ArrayList(ScoredCandidate).init(allocator);
        errdefer heap.deinit();

        var passed: u64 = 0;
        const limit_k = @max(1, top_k);

        for (records, 0..) |*rec, idx| {
            if (idx + 4 < records.len) {
                @prefetch(&records[idx + 4], .{ .rw = .read, .locality = 3, .cache = .data });
            }
            if ((rec.flags & 1) != 0) continue;
            if (deleted_bitset) |bs| {
                if (idx < bs.bit_length and bs.isSet(idx)) continue;
            }
            if (rec.quality_permille < min_quality_permille) continue;
            if (min_published_ms > 0 and rec.published_at_ms < min_published_ms) continue;
            if (max_published_ms > 0 and rec.published_at_ms > max_published_ms) continue;

            passed += 1;
            const raw_score = self.dispatcher.score(lut, &rec.packed_binary);
            const comp_score = norm_compensation.computeNormCompensatedScore(
                raw_score,
                lut.query_l2_norm,
                rec.original_norm,
                rec.quality_permille,
                self.norm_params,
            );

            const cand = ScoredCandidate{
                .doc_id = rec.doc_id,
                .centroid_id = rec.centroid_id,
                .raw_binary_score = raw_score,
                .compensated_score = comp_score,
                .published_at_ms = rec.published_at_ms,
                .quality_permille = rec.quality_permille,
            };

            if (heap.items.len < limit_k) {
                try heap.append(cand);
            } else {
                var worst_idx: usize = 0;
                for (heap.items[1..], 1..) |item, h_idx| {
                    if (numeric_stability.deterministicTieBreakLessThan(
                        heap.items[worst_idx].compensated_score,
                        heap.items[worst_idx].doc_id,
                        item.compensated_score,
                        item.doc_id,
                    )) {
                        worst_idx = h_idx;
                    }
                }
                if (numeric_stability.deterministicTieBreakLessThan(
                    cand.compensated_score,
                    cand.doc_id,
                    heap.items[worst_idx].compensated_score,
                    heap.items[worst_idx].doc_id,
                )) {
                    heap.items[worst_idx] = cand;
                }
            }
        }

        std.mem.sort(ScoredCandidate, heap.items, {}, struct {
            fn lessThan(_: void, a: ScoredCandidate, b: ScoredCandidate) bool {
                return numeric_stability.deterministicTieBreakLessThan(
                    a.compensated_score,
                    a.doc_id,
                    b.compensated_score,
                    b.doc_id,
                );
            }
        }.lessThan);

        const elapsed_ns = @max(1, sw.elapsedNanos());
        _ = self.total_scanned.fetchAdd(records.len, .monotonic);
        _ = self.total_nanos.fetchAdd(elapsed_ns, .monotonic);

        const throughput = (@as(u128, records.len) * 1_000_000_000) / elapsed_ns;
        return .{
            .results = try heap.toOwnedSlice(),
            .telemetry = .{
                .candidates_scanned = records.len,
                .candidates_passed_filter = passed,
                .elapsed_nanos = elapsed_ns,
                .throughput_candidates_per_sec = @intCast(throughput),
                .bytes_streamed = records.len * @sizeOf(AlignedCandidateScanRecord),
            },
        };
    }
};
