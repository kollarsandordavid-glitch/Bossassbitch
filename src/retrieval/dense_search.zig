const std = @import("std");
const vector_index = @import("../index/vector_index.zig");
const filter_engine = @import("../index/filter_engine.zig");
const cluster_probe = @import("cluster_probe.zig");
const lookup_tables = @import("../scoring/lookup_tables.zig");
const candidate_scanner = @import("../scoring/candidate_scanner.zig");
const cancellation = @import("../runtime/cancellation.zig");

pub const DenseSearchResponse = struct {
    candidates: []candidate_scanner.ScoredCandidate,
    selected_nprobe: u32,
    widened_fallback_used: bool,
    is_complete: bool,

    pub fn deinit(self: *DenseSearchResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.candidates);
    }
};

pub fn executeDenseVectorSearch(
    allocator: std.mem.Allocator,
    index: *vector_index.DistributedVectorIndex,
    query_retained: *const [256]f32,
    query_packed: *const [32]u8,
    filters: filter_engine.CompoundFilterCriteria,
    top_k: usize,
    token: *const cancellation.CancellationToken,
) !DenseSearchResponse {
    const lut = lookup_tables.QueryLookupTables.build(query_retained);
    var probe_plan = try cluster_probe.computeAdaptiveProbePlan(
        allocator,
        &index.centroids,
        query_packed,
        16,
        4,
        256,
        token.remainingMillis(),
        filters,
    );
    defer probe_plan.deinit(allocator);

    var f_engine = index.filterEngine();
    var merged = std.ArrayList(candidate_scanner.ScoredCandidate).init(allocator);
    errdefer merged.deinit();

    var visited_shards = std.AutoHashMap(u32, void).init(allocator);
    defer visited_shards.deinit();

    var complete = true;
    for (probe_plan.probed_centroids) |probe| {
        if (token.isCancelled()) {
            complete = false;
            break;
        }
        const sid = index.shards.shardForCentroid(probe.centroid_id);
        if (visited_shards.contains(sid)) continue;
        try visited_shards.put(sid, {});

        const shard_cands = try index.shards.searchShard(
            allocator,
            sid,
            &lut,
            filters.min_quality_permille,
            filters.min_published_at_ms,
            filters.max_published_at_ms,
            top_k,
        );
        defer allocator.free(shard_cands);

        for (shard_cands) |cand| {
            if (index.deletions.isDeleted(cand.doc_id)) continue;
            if (f_engine.matchesDocument(cand.doc_id, filters)) {
                try merged.append(cand);
            }
        }
    }

    var widened_fallback = probe_plan.widened_for_strict_filter;
    if (merged.items.len == 0 and !token.isCancelled()) {
        widened_fallback = true;
        for (0..index.shards.shards.len) |s_idx| {
            const sid: u32 = @intCast(s_idx);
            if (visited_shards.contains(sid)) continue;
            if (token.isCancelled()) {
                complete = false;
                break;
            }
            const shard_cands = try index.shards.searchShard(
                allocator,
                sid,
                &lut,
                filters.min_quality_permille,
                filters.min_published_at_ms,
                filters.max_published_at_ms,
                top_k,
            );
            defer allocator.free(shard_cands);

            for (shard_cands) |cand| {
                if (index.deletions.isDeleted(cand.doc_id)) continue;
                if (f_engine.matchesDocument(cand.doc_id, filters)) {
                    try merged.append(cand);
                }
            }
        }
    }

    return .{
        .candidates = try merged.toOwnedSlice(),
        .selected_nprobe = probe_plan.selected_nprobe,
        .widened_fallback_used = widened_fallback,
        .is_complete = complete,
    };
}
