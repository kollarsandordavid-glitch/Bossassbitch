const std = @import("std");
const time_util = @import("../util/time.zig");

pub const StageBudgetPlan = struct {
    root_started_ms: u64,
    hard_deadline_ms: u64,
    sparse_deadline_ms: u64,
    dense_deadline_ms: u64,
    rerank_deadline_ms: u64,
    highlights_deadline_ms: u64,
    verification_deadline_ms: u64,

    pub fn build(
        total_budget_ms: u64,
        sparse_budget_ms: u64,
        dense_budget_ms: u64,
        rerank_budget_ms: u64,
        highlights_budget_ms: u64,
        verification_budget_ms: u64,
    ) StageBudgetPlan {
        const now = time_util.nowMillis();
        const hard_end = now + @max(5, total_budget_ms);
        return .{
            .root_started_ms = now,
            .hard_deadline_ms = hard_end,
            .sparse_deadline_ms = @min(hard_end, now + sparse_budget_ms),
            .dense_deadline_ms = @min(hard_end, now + dense_budget_ms),
            .rerank_deadline_ms = @min(hard_end, now + dense_budget_ms + rerank_budget_ms),
            .highlights_deadline_ms = @min(hard_end, now + dense_budget_ms + rerank_budget_ms + highlights_budget_ms),
            .verification_deadline_ms = @min(hard_end, now + dense_budget_ms + rerank_budget_ms + verification_budget_ms),
        };
    }

    pub fn isHardDeadlineExpired(self: StageBudgetPlan) bool {
        return time_util.nowMillis() >= self.hard_deadline_ms;
    }

    pub fn remainingTotalMillis(self: StageBudgetPlan) u64 {
        const now = time_util.nowMillis();
        return if (now >= self.hard_deadline_ms) 0 else self.hard_deadline_ms - now;
    }
};
