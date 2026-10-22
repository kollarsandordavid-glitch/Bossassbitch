const std = @import("std");

pub const MinedHardNegative = struct {
    query_hash: u64,
    negative_doc_id: u64,
    model_version: u32,
    index_generation: u64,
    scoring_version: u16,
    retrieved_at_ms: u64,
    similarity_score: f32,
    pool_weight: f32,
    retained_embedding: [256]f32,
};

pub const NegativePoolWeightInputs = struct {
    lexical_overlap_permille: u16,
    semantic_relevance_permille: u16,
    source_authority_permille: u16,
    source_originality_permille: u16,
    graph_quality_permille: u16,
    is_aggregator_or_listicle: bool,
};

pub fn computeCalibratedCandidatePoolWeight(inp: NegativePoolWeightInputs) f32 {
    var weight: f32 = 1.0;
    if (inp.is_aggregator_or_listicle and inp.source_originality_permille < 400) {
        weight += 0.65;
    }
    if (inp.lexical_overlap_permille > 750 and inp.semantic_relevance_permille < 350) {
        weight += 0.45;
    }
    if (inp.source_authority_permille > 800 and inp.source_originality_permille > 750 and inp.semantic_relevance_permille > 750) {
        weight *= 0.35;
    }
    return std.math.clamp(weight, 0.1, 2.5);
}

pub const HardNegativeMiner = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    capacity: usize,
    max_version_lag: u32,
    pool: std.ArrayList(MinedHardNegative),
    stale_rejected_count: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, capacity: usize, max_version_lag: u32) HardNegativeMiner {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .capacity = @max(64, capacity),
            .max_version_lag = max_version_lag,
            .pool = std.ArrayList(MinedHardNegative).init(allocator),
            .stale_rejected_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *HardNegativeMiner) void {
        self.pool.deinit();
    }

    pub fn enqueueCandidate(
        self: *HardNegativeMiner,
        candidate: MinedHardNegative,
        current_model_version: u32,
    ) !bool {
        if (current_model_version > candidate.model_version + self.max_version_lag) {
            _ = self.stale_rejected_count.fetchAdd(1, .monotonic);
            return false;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.pool.items) |existing| {
            if (existing.query_hash == candidate.query_hash and existing.negative_doc_id == candidate.negative_doc_id) {
                return false;
            }
        }

        if (self.pool.items.len >= self.capacity) {
            _ = self.pool.orderedRemove(0);
        }
        try self.pool.append(candidate);
        return true;
    }

    pub fn selectFreshNegatives(
        self: *HardNegativeMiner,
        allocator: std.mem.Allocator,
        current_model_version: u32,
        max_count: usize,
    ) ![]MinedHardNegative {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out = std.ArrayList(MinedHardNegative).init(allocator);
        errdefer out.deinit();

        var i: usize = 0;
        while (i < self.pool.items.len and out.items.len < max_count) {
            const item = self.pool.items[i];
            if (current_model_version > item.model_version + self.max_version_lag) {
                _ = self.pool.orderedRemove(i);
                _ = self.stale_rejected_count.fetchAdd(1, .monotonic);
                continue;
            }
            try out.append(item);
            i += 1;
        }
        return out.toOwnedSlice();
    }
};
