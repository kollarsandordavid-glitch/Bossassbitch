const std = @import("std");
const candidate_scanner = @import("../scoring/candidate_scanner.zig");
const lookup_tables = @import("../scoring/lookup_tables.zig");
const mmap_store = @import("mmap_store.zig");
const compaction = @import("compaction.zig");
const deletion_manager = @import("deletion_manager.zig");
const platform = @import("../util/platform.zig");

pub const IndexShard = struct {
    allocator: std.mem.Allocator,
    shard_id: u32,
    numa_node: u32,
    centroid_start: u32,
    centroid_end: u32,
    mutex: std.Thread.Mutex,
    records: std.ArrayList(candidate_scanner.AlignedCandidateScanRecord),
    query_count: std.atomic.Value(u64),

    pub fn init(
        allocator: std.mem.Allocator,
        shard_id: u32,
        numa_node: u32,
        centroid_start: u32,
        centroid_end: u32,
    ) IndexShard {
        return .{
            .allocator = allocator,
            .shard_id = shard_id,
            .numa_node = numa_node,
            .centroid_start = centroid_start,
            .centroid_end = centroid_end,
            .mutex = .{},
            .records = std.ArrayList(candidate_scanner.AlignedCandidateScanRecord).init(allocator),
            .query_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *IndexShard) void {
        self.records.deinit();
    }

    pub fn appendRecord(self: *IndexShard, rec: candidate_scanner.AlignedCandidateScanRecord) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.records.append(rec);
    }

    pub fn recordCount(self: *IndexShard) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.records.items.len;
    }
};

pub const ShardManager = struct {
    allocator: std.mem.Allocator,
    total_centroids: u32,
    shards: []IndexShard,
    scanner: candidate_scanner.CandidateScanner,

    pub fn init(
        allocator: std.mem.Allocator,
        shard_count: u32,
        total_centroids: u32,
    ) !ShardManager {
        const count: usize = @max(1, @as(usize, @intCast(shard_count)));
        const topo = platform.detectTopology();
        const centroids_per_shard: u32 = (total_centroids + @as(u32, @intCast(count)) - 1) / @as(u32, @intCast(count));

        const shards = try allocator.alloc(IndexShard, count);
        for (0..count) |i| {
            const sid: u32 = @intCast(i);
            const c_start = sid * centroids_per_shard;
            const c_end = @min(total_centroids, c_start + centroids_per_shard);
            const numa = platform.selectNumaNodeForShard(sid, topo);
            shards[i] = IndexShard.init(allocator, sid, numa, c_start, c_end);
        }

        return .{
            .allocator = allocator,
            .total_centroids = total_centroids,
            .shards = shards,
            .scanner = candidate_scanner.CandidateScanner.init(),
        };
    }

    pub fn deinit(self: *ShardManager) void {
        for (self.shards) |*s| s.deinit();
        self.allocator.free(self.shards);
    }

    pub fn shardForCentroid(self: *const ShardManager, centroid_id: u32) u32 {
        const count: u32 = @intCast(self.shards.len);
        const per_shard = (self.total_centroids + count - 1) / count;
        return @min(count - 1, centroid_id / @max(1, per_shard));
    }

    pub fn insertRecord(self: *ShardManager, rec: candidate_scanner.AlignedCandidateScanRecord) !u32 {
        const sid = self.shardForCentroid(rec.centroid_id);
        try self.shards[sid].appendRecord(rec);
        return sid;
    }

    pub fn searchShard(
        self: *ShardManager,
        allocator: std.mem.Allocator,
        shard_id: u32,
        lut: *const lookup_tables.QueryLookupTables,
        min_quality_permille: u16,
        min_published_ms: u64,
        max_published_ms: u64,
        top_k: usize,
    ) ![]candidate_scanner.ScoredCandidate {
        if (shard_id >= self.shards.len) return allocator.alloc(candidate_scanner.ScoredCandidate, 0);
        var shard = &self.shards[shard_id];
        _ = shard.query_count.fetchAdd(1, .monotonic);

        shard.mutex.lock();
        const snapshot_slice = try allocator.dupe(candidate_scanner.AlignedCandidateScanRecord, shard.records.items);
        shard.mutex.unlock();
        defer allocator.free(snapshot_slice);

        const scan_res = try self.scanner.scanBlockTopK(
            allocator,
            lut,
            snapshot_slice,
            null,
            min_quality_permille,
            min_published_ms,
            max_published_ms,
            top_k,
        );
        return scan_res.results;
    }

    pub fn compactAllShards(
        self: *ShardManager,
        store: *mmap_store.MmapSegmentStore,
        deletions: *deletion_manager.DeletionManager,
        generation_id: u64,
    ) !usize {
        var total_purged: usize = 0;
        for (self.shards) |*shard| {
            shard.mutex.lock();
            const res = try compaction.compactSegmentRecords(self.allocator, shard.records.items, deletions);
            shard.records.clearRetainingCapacity();
            try shard.records.appendSlice(res.compacted);
            self.allocator.free(res.compacted);
            _ = try store.writeImmutableSegment(shard.shard_id, generation_id, shard.records.items);
            total_purged += res.stats.purged_tombstones;
            shard.mutex.unlock();
        }
        return total_purged;
    }
};
