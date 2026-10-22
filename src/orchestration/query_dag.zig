const std = @import("std");
const query_router = @import("../retrieval/query_router.zig");
const candidate_merge = @import("../retrieval/candidate_merge.zig");
const highlight_extractor = @import("../highlights/highlight_extractor.zig");
const citation_verifier = @import("../retrieval/citation_verifier.zig");
const entity_classifier = @import("../models/entity_classifier.zig");

pub const DagNodeState = enum(u8) {
    pending = 0,
    running = 1,
    completed = 2,
    skipped = 3,
    cancelled = 4,
    failed = 5,
};

pub const DagExecutionResult = struct {
    routing_decision: query_router.RoutingDecision,
    ranked_candidates: []candidate_merge.UnifiedCandidate,
    highlights: []highlight_extractor.GroundedHighlight,
    verified_claims: []citation_verifier.VerifiedClaimRecord,
    entities: []entity_classifier.ExtractedEntity,
    node_states: [9]DagNodeState,
    node_durations_micros: [9]u64,
    total_elapsed_ms: u64,
    selected_nprobe: u32,
    widened_probe_used: bool,
    retrieval_complete: bool,
    index_generation: u64,
    model_version: u32,

    pub fn deinit(self: *DagExecutionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.ranked_candidates);
        for (self.highlights) |*h| h.deinit(allocator);
        allocator.free(self.highlights);
        for (self.verified_claims) |*c| c.deinit(allocator);
        allocator.free(self.verified_claims);
        for (self.entities) |*e| e.deinit(allocator);
        allocator.free(self.entities);
    }
};
