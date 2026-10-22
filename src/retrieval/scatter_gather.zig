const std = @import("std");
const candidate_scanner = @import("../scoring/candidate_scanner.zig");
const numeric_stability = @import("../scoring/numeric_stability.zig");

pub const ScatterGatherSummary = struct {
    shards_contacted: u32,
    shards_succeeded: u32,
    shards_failed: u32,
    candidates_merged: u32,
};

pub fn mergeDistributedShardCandidates(
    allocator: std.mem.Allocator,
    shard_batches: []const []const candidate_scanner.ScoredCandidate,
    top_k: usize,
) !struct { candidates: []candidate_scanner.ScoredCandidate, summary: ScatterGatherSummary } {
    var seen_docs = std.AutoHashMap(u64, candidate_scanner.ScoredCandidate).init(allocator);
    defer seen_docs.deinit();

    var contacted: u32 = 0;
    var succeeded: u32 = 0;

    for (shard_batches) |batch| {
        contacted += 1;
        succeeded += 1;
        for (batch) |cand| {
            const gop = try seen_docs.getOrPut(cand.doc_id);
            if (!gop.found_existing or cand.compensated_score > gop.value_ptr.compensated_score) {
                gop.value_ptr.* = cand;
            }
        }
    }

    var merged = std.ArrayList(candidate_scanner.ScoredCandidate).init(allocator);
    errdefer merged.deinit();

    var it = seen_docs.valueIterator();
    while (it.next()) |cand| {
        try merged.append(cand.*);
    }

    std.mem.sort(candidate_scanner.ScoredCandidate, merged.items, {}, struct {
        fn lessThan(_: void, a: candidate_scanner.ScoredCandidate, b: candidate_scanner.ScoredCandidate) bool {
            return numeric_stability.deterministicTieBreakLessThan(
                a.compensated_score,
                a.doc_id,
                b.compensated_score,
                b.doc_id,
            );
        }
    }.lessThan);

    if (merged.items.len > top_k) {
        merged.shrinkRetainingCapacity(top_k);
    }

    const count: u32 = @intCast(merged.items.len);
    return .{
        .candidates = try merged.toOwnedSlice(),
        .summary = .{
            .shards_contacted = contacted,
            .shards_succeeded = succeeded,
            .shards_failed = 0,
            .candidates_merged = count,
        },
    };
}
