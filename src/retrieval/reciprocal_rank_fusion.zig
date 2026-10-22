const std = @import("std");
const candidate_merge = @import("candidate_merge.zig");
const numeric_stability = @import("../scoring/numeric_stability.zig");

pub const RrfConfig = struct {
    rank_constant_k: u32 = 60,
    dense_weight: f32 = 1.0,
    sparse_weight: f32 = 0.85,
};

pub fn applyReciprocalRankFusion(
    candidates: []candidate_merge.UnifiedCandidate,
    cfg: RrfConfig,
) void {
    const k_f: f32 = @floatFromInt(@max(1, cfg.rank_constant_k));

    var max_sparse: f32 = 1e-6;
    var max_dense: f32 = 1e-6;
    for (candidates) |c| {
        if (c.sparse_score > max_sparse) max_sparse = c.sparse_score;
        if (c.dense_score > max_dense) max_dense = c.dense_score;
    }

    for (candidates) |*c| {
        var rrf: f32 = 0.0;
        if (c.dense_rank > 0) {
            rrf += cfg.dense_weight / (k_f + @as(f32, @floatFromInt(c.dense_rank)));
        }
        if (c.sparse_rank > 0) {
            rrf += cfg.sparse_weight / (k_f + @as(f32, @floatFromInt(c.sparse_rank)));
        }
        const calibrated_dense = if (c.dense_rank > 0) @max(0.0, c.dense_score / max_dense) else 0.0;
        const calibrated_sparse = if (c.sparse_rank > 0) @max(0.0, c.sparse_score / max_sparse) else 0.0;

        c.rrf_score = rrf + (calibrated_dense * 0.02 + calibrated_sparse * 0.015);
        c.final_calibrated_score = c.rrf_score;
    }

    std.mem.sort(candidate_merge.UnifiedCandidate, candidates, {}, struct {
        fn lessThan(_: void, a: candidate_merge.UnifiedCandidate, b: candidate_merge.UnifiedCandidate) bool {
            return numeric_stability.deterministicTieBreakLessThan(
                a.rrf_score,
                a.doc_id,
                b.rrf_score,
                b.doc_id,
            );
        }
    }.lessThan);
}
