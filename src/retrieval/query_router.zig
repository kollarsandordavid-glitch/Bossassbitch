const std = @import("std");
const query_parser = @import("query_parser.zig");
const filter_engine = @import("../index/filter_engine.zig");

pub const RouteStrategy = enum(u8) {
    dense_semantic = 0,
    sparse_exact = 1,
    hybrid_lexical_semantic = 2,
    code_search_vertical = 3,
    executive_profile_vertical = 4,
    research_publication_vertical = 5,
    structured_filter_priority = 6,
    multi_step_research_dag = 7,

    pub fn toString(self: RouteStrategy) []const u8 {
        return switch (self) {
            .dense_semantic => "dense",
            .sparse_exact => "sparse",
            .hybrid_lexical_semantic => "hybrid",
            .code_search_vertical => "code",
            .executive_profile_vertical => "executive",
            .research_publication_vertical => "research_publications",
            .structured_filter_priority => "structured",
            .multi_step_research_dag => "research_dag",
        };
    }
};

pub const RoutingDecision = struct {
    strategy: RouteStrategy,
    execute_sparse_branch: bool,
    execute_dense_branch: bool,
    execute_rerank_branch: bool,
    candidate_pool_k: u32,
    estimated_cost_units: u32,
};

pub fn routeQuery(
    parsed: *const query_parser.ParsedQuery,
    requested_mode: []const u8,
    filters: filter_engine.CompoundFilterCriteria,
    requested_pool_k: u32,
) RoutingDecision {
    const pool_k: u32 = if (requested_pool_k == 5000) 5000 else 500;

    if (std.mem.eql(u8, requested_mode, "dense")) {
        return .{
            .strategy = .dense_semantic,
            .execute_sparse_branch = false,
            .execute_dense_branch = true,
            .execute_rerank_branch = true,
            .candidate_pool_k = pool_k,
            .estimated_cost_units = 40,
        };
    }
    if (std.mem.eql(u8, requested_mode, "sparse")) {
        return .{
            .strategy = .sparse_exact,
            .execute_sparse_branch = true,
            .execute_dense_branch = false,
            .execute_rerank_branch = false,
            .candidate_pool_k = pool_k,
            .estimated_cost_units = 15,
        };
    }
    if (std.mem.eql(u8, requested_mode, "code") or parsed.has_code_syntax) {
        return .{
            .strategy = .code_search_vertical,
            .execute_sparse_branch = true,
            .execute_dense_branch = true,
            .execute_rerank_branch = true,
            .candidate_pool_k = pool_k,
            .estimated_cost_units = 65,
        };
    }
    if (std.mem.eql(u8, requested_mode, "executive") or parsed.has_executive_intent) {
        return .{
            .strategy = .executive_profile_vertical,
            .execute_sparse_branch = true,
            .execute_dense_branch = true,
            .execute_rerank_branch = true,
            .candidate_pool_k = pool_k,
            .estimated_cost_units = 60,
        };
    }
    if (std.mem.eql(u8, requested_mode, "research_publications") or parsed.has_research_intent) {
        return .{
            .strategy = .research_publication_vertical,
            .execute_sparse_branch = true,
            .execute_dense_branch = true,
            .execute_rerank_branch = true,
            .candidate_pool_k = pool_k,
            .estimated_cost_units = 75,
        };
    }
    if (!filters.isEmpty() and filters.estimateSelectivityPermille() < 200) {
        return .{
            .strategy = .structured_filter_priority,
            .execute_sparse_branch = true,
            .execute_dense_branch = true,
            .execute_rerank_branch = true,
            .candidate_pool_k = pool_k,
            .estimated_cost_units = 50,
        };
    }
    if (parsed.has_quotes and parsed.terms.len <= 3) {
        return .{
            .strategy = .sparse_exact,
            .execute_sparse_branch = true,
            .execute_dense_branch = true,
            .execute_rerank_branch = true,
            .candidate_pool_k = pool_k,
            .estimated_cost_units = 45,
        };
    }

    return .{
        .strategy = .hybrid_lexical_semantic,
        .execute_sparse_branch = true,
        .execute_dense_branch = true,
        .execute_rerank_branch = true,
        .candidate_pool_k = pool_k,
        .estimated_cost_units = 60,
    };
}
