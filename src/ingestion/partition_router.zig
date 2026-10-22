const std = @import("std");
const hashing = @import("../util/hashing.zig");

pub const PartitionRouter = struct {
    partition_count: u32,
    ring_seeds: [16]u64,

    pub fn init(partition_count: u32) PartitionRouter {
        var seeds: [16]u64 = undefined;
        for (0..16) |i| {
            seeds[i] = 0x9e3779b97f4a7c15 ^ (@as(u64, @intCast(i + 1)) *% 0xbf58476d1ce4e5b9);
        }
        return .{
            .partition_count = @max(1, partition_count),
            .ring_seeds = seeds,
        };
    }

    pub fn routeByDocId(self: PartitionRouter, doc_id: u64) u32 {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, doc_id, .little);
        const h = hashing.wyhash64(&bytes, self.ring_seeds[0]);
        return @intCast(h % @as(u64, self.partition_count));
    }

    pub fn routeByCanonicalUrl(self: PartitionRouter, canonical_url: []const u8) u32 {
        const h = hashing.wyhash64(canonical_url, self.ring_seeds[1]);
        return @intCast(h % @as(u64, self.partition_count));
    }

    pub fn routeReplicas(self: PartitionRouter, key_hash: u64, replication_factor: u32, out_replicas: []u32) usize {
        const limit = @min(@as(usize, replication_factor), @min(out_replicas.len, @as(usize, self.partition_count)));
        var chosen: usize = 0;
        var attempt: usize = 0;
        while (chosen < limit and attempt < 64) : (attempt += 1) {
            const mixed = hashing.mix64(key_hash +% (@as(u64, @intCast(attempt)) *% 0x94d049bb133111eb));
            const candidate: u32 = @intCast(mixed % @as(u64, self.partition_count));
            var duplicate = false;
            for (out_replicas[0..chosen]) |existing| {
                if (existing == candidate) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                out_replicas[chosen] = candidate;
                chosen += 1;
            }
        }
        return chosen;
    }
};
