const std = @import("std");
const query_router = @import("../retrieval/query_router.zig");

pub const SpeculativeBranchDecision = struct {
    launch_speculative_sparse: bool,
    launch_speculative_dense: bool,
    expected_benefit_permille: u16,
    estimated_cost_ms: u64,
};

pub fn evaluateSpeculativeExecution(
    routing: query_router.RoutingDecision,
    remaining_budget_ms: u64,
    speculative_threshold_ms: u64,
) SpeculativeBranchDecision {
    if (remaining_budget_ms <= speculative_threshold_ms) {
        return .{
            .launch_speculative_sparse = false,
            .launch_speculative_dense = false,
            .expected_benefit_permille = 0,
            .estimated_cost_ms = 0,
        };
    }

    if (routing.strategy == .dense_semantic and !routing.execute_sparse_branch) {
        return .{
            .launch_speculative_sparse = true,
            .launch_speculative_dense = false,
            .expected_benefit_permille = 320,
            .estimated_cost_ms = 8,
        };
    }

    if (routing.strategy == .sparse_exact and !routing.execute_dense_branch) {
        return .{
            .launch_speculative_sparse = false,
            .launch_speculative_dense = true,
            .expected_benefit_permille = 410,
            .estimated_cost_ms = 14,
        };
    }

    return .{
        .launch_speculative_sparse = false,
        .launch_speculative_dense = false,
        .expected_benefit_permille = 100,
        .estimated_cost_ms = 0,
    };
}
