const std = @import("std");
const clustering = @import("clustering.zig");
const simd_dispatch = @import("../scoring/simd_dispatch.zig");

pub const CentroidMeta = struct {
    centroid_id: u32,
    packed_signature: [32]u8,
    occupancy: u64,
    query_hits: u64,
    cumulative_drift_milli: u32,
    is_hot_replicated: bool,
};

pub const CentroidManager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    total_centroids: u32,
    split_threshold: u64,
    drift_threshold_milli: u32,
    dispatcher: simd_dispatch.SimdDispatcher,
    active_centroids: std.AutoHashMap(u32, CentroidMeta),

    pub fn init(
        allocator: std.mem.Allocator,
        total_centroids: u32,
        split_threshold: u64,
        drift_threshold_milli: u32,
    ) CentroidManager {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .total_centroids = if (total_centroids == 0) clustering.TOTAL_SEMANTIC_CENTROIDS else total_centroids,
            .split_threshold = split_threshold,
            .drift_threshold_milli = drift_threshold_milli,
            .dispatcher = simd_dispatch.SimdDispatcher.initAuto(),
            .active_centroids = std.AutoHashMap(u32, CentroidMeta).init(allocator),
        };
    }

    pub fn deinit(self: *CentroidManager) void {
        self.active_centroids.deinit();
    }

    pub fn assignDocumentToCentroid(
        self: *CentroidManager,
        packed_binary: *const [32]u8,
    ) !u32 {
        const bucket = std.mem.readInt(u32, packed_binary[0..4], .little) % self.total_centroids;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.active_centroids.getPtr(bucket)) |meta| {
            meta.occupancy += 1;
            const ham = self.dispatcher.hamming(packed_binary, &meta.packed_signature);
            meta.cumulative_drift_milli = (meta.cumulative_drift_milli * 9 + (ham * 1000) / 256) / 10;
            if (meta.occupancy >= self.split_threshold) {
                const split_target = (bucket + 49999) % self.total_centroids;
                if (!self.active_centroids.contains(split_target)) {
                    try self.active_centroids.put(split_target, .{
                        .centroid_id = split_target,
                        .packed_signature = packed_binary.*,
                        .occupancy = 1,
                        .query_hits = 0,
                        .cumulative_drift_milli = 0,
                        .is_hot_replicated = false,
                    });
                    return split_target;
                }
            }
            return bucket;
        } else {
            try self.active_centroids.put(bucket, .{
                .centroid_id = bucket,
                .packed_signature = packed_binary.*,
                .occupancy = 1,
                .query_hits = 0,
                .cumulative_drift_milli = 0,
                .is_hot_replicated = false,
            });
            return bucket;
        }
    }

    pub const RankedCentroidProbe = struct {
        centroid_id: u32,
        hamming_distance: u32,
        similarity: f32,
    };

    pub fn rankCentroidsForQuery(
        self: *CentroidManager,
        allocator: std.mem.Allocator,
        query_packed: *const [32]u8,
        max_probes: usize,
    ) ![]RankedCentroidProbe {
        self.mutex.lock();
        defer self.mutex.unlock();

        var probes = std.ArrayList(RankedCentroidProbe).init(allocator);
        errdefer probes.deinit();

        var it = self.active_centroids.valueIterator();
        while (it.next()) |meta| {
            meta.query_hits += 1;
            if (meta.query_hits > 10000) {
                meta.is_hot_replicated = true;
            }
            const dist = self.dispatcher.hamming(query_packed, &meta.packed_signature);
            const sim = (@as(f32, 256.0) - @as(f32, @floatFromInt(dist * 2))) / 256.0;
            try probes.append(.{
                .centroid_id = meta.centroid_id,
                .hamming_distance = dist,
                .similarity = sim,
            });
        }

        std.mem.sort(RankedCentroidProbe, probes.items, {}, struct {
            fn lessThan(_: void, a: RankedCentroidProbe, b: RankedCentroidProbe) bool {
                if (a.hamming_distance != b.hamming_distance) {
                    return a.hamming_distance < b.hamming_distance;
                }
                return a.centroid_id < b.centroid_id;
            }
        }.lessThan);

        if (probes.items.len > max_probes) {
            probes.shrinkRetainingCapacity(max_probes);
        }
        return probes.toOwnedSlice();
    }
};
