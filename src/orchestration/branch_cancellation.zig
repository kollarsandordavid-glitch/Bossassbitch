const std = @import("std");
const cancellation = @import("../runtime/cancellation.zig");

pub const DagBranchId = enum(u8) {
    query_router = 0,
    sparse_bm25 = 1,
    dense_vector = 2,
    speculative_fallback = 3,
    candidate_fusion = 4,
    neural_reranker = 5,
    highlight_extraction = 6,
    claim_verification = 7,
    entity_extraction = 8,
};

pub const BranchCancellationController = struct {
    root_token: cancellation.CancellationToken,
    branch_tokens: [9]cancellation.CancellationToken,
    cancelled_branches_mask: std.atomic.Value(u16),

    pub fn init(total_deadline_ms: u64) BranchCancellationController {
        var ctrl: BranchCancellationController = undefined;
        ctrl.root_token = cancellation.CancellationToken.initWithDeadline(total_deadline_ms, null);
        ctrl.cancelled_branches_mask = std.atomic.Value(u16).init(0);
        for (0..9) |i| {
            ctrl.branch_tokens[i] = cancellation.CancellationToken.initWithDeadline(total_deadline_ms, null);
        }
        return ctrl;
    }

    pub fn cancelBranch(
        self: *BranchCancellationController,
        branch: DagBranchId,
        reason: cancellation.CancellationReason,
    ) void {
        const idx: usize = @intFromEnum(branch);
        self.branch_tokens[idx].cancel(reason);
        _ = self.cancelled_branches_mask.fetchOr(@as(u16, 1) << @intCast(idx), .acq_rel);
    }

    pub fn cancelNonEssentialAfterSufficientCandidates(
        self: *BranchCancellationController,
        found_candidates: usize,
        required_k: usize,
    ) void {
        if (found_candidates >= required_k * 2) {
            self.cancelBranch(.speculative_fallback, .sufficient_candidates);
        }
    }

    pub fn cancelledBranchCount(self: *const BranchCancellationController) u32 {
        return @popCount(self.cancelled_branches_mask.load(.acquire));
    }
};
