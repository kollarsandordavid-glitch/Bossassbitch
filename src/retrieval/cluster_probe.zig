const std = @import("std");
const centroid_manager = @import("../index/centroid_manager.zig");
const filter_engine = @import("../index/filter_engine.zig");

pub const AdaptiveProbePlan = struct {
    selected_nprobe: u32,
    widened_for_strict_filter: bool,
    probed_centroids: []centroid_manager.CentroidManager.RankedCentroidProbe,

    pub fn deinit(self: *AdaptiveProbePlan, allocator: std.mem.Allocator) void {
        allocator.free(self.probed_centroids);
    }
};

pub fn computeAdaptiveProbePlan(
    allocator: std.mem.Allocator,
    centroids: *centroid_manager.CentroidManager,
    query_packed: *const [32]u8,
    default_nprobe: u32,
    min_nprobe: u32,
    max_nprobe: u32,
    remaining_budget_ms: u64,
    filters: filter_engine.CompoundFilterCriteria,
) !AdaptiveProbePlan {
    const ranked = try centroids.rankCentroidsForQuery(allocator, query_packed, max_nprobe);
    errdefer allocator.free(ranked);

    var target_nprobe = default_nprobe;
    if (ranked.len >= 2) {
        const top_sim = ranked[0].similarity;
        const second_sim = ranked[1].similarity;
        const margin = top_sim - second_sim;
        if (margin >= 0.18) {
            target_nprobe = @max(min_nprobe, default_nprobe / 2);
        } else if (margin <= 0.04) {
            target_nprobe = @min(max_nprobe, default_nprobe * 2);
        }
    }

    var widened = false;
    const selectivity = filters.estimateSelectivityPermille();
    if (selectivity < 250) {
        target_nprobe = @min(max_nprobe, target_nprobe * 3);
        widened = true;
    }

    if (remaining_budget_ms < 15) {
        target_nprobe = @max(min_nprobe, target_nprobe / 2);
    }

    const final_count = @min(ranked.len, @as(usize, @intCast(target_nprobe)));
    const sliced = try allocator.dupe(centroid_manager.CentroidManager.RankedCentroidProbe, ranked[0..final_count]);
    allocator.free(ranked);

    return .{
        .selected_nprobe = @intCast(final_count),
        .widened_for_strict_filter = widened,
        .probed_centroids = sliced,
    };
}
