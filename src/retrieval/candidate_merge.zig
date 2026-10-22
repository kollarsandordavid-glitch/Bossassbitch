const std = @import("std");
const candidate_scanner = @import("../scoring/candidate_scanner.zig");
const bm25 = @import("bm25.zig");

pub const UnifiedCandidate = struct {
    doc_id: u64,
    centroid_id: u32,
    dense_rank: u32,
    sparse_rank: u32,
    dense_score: f32,
    sparse_score: f32,
    rrf_score: f32,
    reranker_score: f32,
    final_calibrated_score: f32,
    published_at_ms: u64,
    quality_permille: u16,
};

pub fn deduplicateAndCombinePools(
    allocator: std.mem.Allocator,
    dense_candidates: []const candidate_scanner.ScoredCandidate,
    sparse_candidates: []const bm25.SparseScoredCandidate,
    max_pool_k: usize,
) ![]UnifiedCandidate {
    var map = std.AutoHashMap(u64, UnifiedCandidate).init(allocator);
    defer map.deinit();

    for (dense_candidates, 0..) |dc, idx| {
        if (idx >= max_pool_k) break;
        try map.put(dc.doc_id, .{
            .doc_id = dc.doc_id,
            .centroid_id = dc.centroid_id,
            .dense_rank = @intCast(idx + 1),
            .sparse_rank = 0,
            .dense_score = dc.compensated_score,
            .sparse_score = 0.0,
            .rrf_score = 0.0,
            .reranker_score = 0.0,
            .final_calibrated_score = dc.compensated_score,
            .published_at_ms = dc.published_at_ms,
            .quality_permille = dc.quality_permille,
        });
    }

    for (sparse_candidates, 0..) |sc, idx| {
        if (idx >= max_pool_k) break;
        const gop = try map.getOrPut(sc.doc_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .doc_id = sc.doc_id,
                .centroid_id = 0,
                .dense_rank = 0,
                .sparse_rank = @intCast(idx + 1),
                .dense_score = 0.0,
                .sparse_score = sc.bm25_score,
                .rrf_score = 0.0,
                .reranker_score = 0.0,
                .final_calibrated_score = sc.bm25_score,
                .published_at_ms = 0,
                .quality_permille = 750,
            };
        } else {
            gop.value_ptr.sparse_rank = @intCast(idx + 1);
            gop.value_ptr.sparse_score = sc.bm25_score;
        }
    }

    var out = std.ArrayList(UnifiedCandidate).init(allocator);
    errdefer out.deinit();
    var it = map.valueIterator();
    while (it.next()) |u| {
        try out.append(u.*);
    }
    return out.toOwnedSlice();
}
