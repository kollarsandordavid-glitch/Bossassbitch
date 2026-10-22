const std = @import("std");
const binary_scoring = @import("../scoring/binary_scoring.zig");
const simd_dispatch = @import("../scoring/simd_dispatch.zig");

pub const TOTAL_SEMANTIC_CENTROIDS: u32 = 100_000;

pub const CentroidAssignment = struct {
    centroid_id: u32,
    similarity_score: f32,
    second_best_centroid_id: u32,
    margin_score: f32,
};

pub fn computeDeterministicCentroidSignature(centroid_id: u32) [32]u8 {
    var out: [32]u8 = undefined;
    var state: u64 = (@as(u64, centroid_id) +% 1) *% 0x9e3779b97f4a7c15;
    for (0..4) |word_idx| {
        state ^= state >> 30;
        state *%= 0xbf58476d1ce4e5b9;
        state ^= state >> 27;
        state *%= 0x94d049bb133111eb;
        state ^= state >> 31;
        std.mem.writeInt(u64, out[word_idx * 8 ..][0..8], state, .little);
    }
    return out;
}

pub fn updateCentroidIncremental(
    centroid_coords: *[256]f32,
    new_vector: *const [256]f32,
    occupancy_count: u64,
) f32 {
    const lr: f32 = 1.0 / @as(f32, @floatFromInt(@min(@max(occupancy_count, 2), 10000)));
    var drift_sq: f32 = 0.0;
    for (0..256) |d| {
        const prev = centroid_coords[d];
        const updated = prev * (1.0 - lr) + new_vector[d] * lr;
        const delta = updated - prev;
        drift_sq += delta * delta;
        centroid_coords[d] = updated;
    }
    return @sqrt(drift_sq);
}

pub fn selectNearestCentroids(
    dispatcher: simd_dispatch.SimdDispatcher,
    packed_vec: *const [32]u8,
    active_centroid_sigs: []const [32]u8,
    active_centroid_ids: []const u32,
) CentroidAssignment {
    if (active_centroid_sigs.len == 0) {
        const direct_id = std.mem.readInt(u32, packed_vec[0..4], .little) % TOTAL_SEMANTIC_CENTROIDS;
        return .{
            .centroid_id = direct_id,
            .similarity_score = 1.0,
            .second_best_centroid_id = (direct_id + 1) % TOTAL_SEMANTIC_CENTROIDS,
            .margin_score = 0.25,
        };
    }

    var best_id: u32 = active_centroid_ids[0];
    var second_id: u32 = active_centroid_ids[0];
    var best_sim: f32 = -2.0;
    var second_sim: f32 = -2.0;

    for (active_centroid_sigs, 0..) |*sig, idx| {
        const ham = dispatcher.hamming(packed_vec, sig);
        const sim = (@as(f32, 256.0) - @as(f32, @floatFromInt(ham * 2))) / 256.0;
        if (sim > best_sim) {
            second_sim = best_sim;
            second_id = best_id;
            best_sim = sim;
            best_id = active_centroid_ids[idx];
        } else if (sim > second_sim) {
            second_sim = sim;
            second_id = active_centroid_ids[idx];
        }
    }

    return .{
        .centroid_id = best_id,
        .similarity_score = best_sim,
        .second_best_centroid_id = second_id,
        .margin_score = @max(0.0, best_sim - second_sim),
    };
}

pub fn unusedRef() void {
    _ = binary_scoring.QUANTIZATION_VERSION;
}
