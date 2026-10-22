const std = @import("std");
const mmap_store = @import("mmap_store.zig");
const snapshots = @import("snapshots.zig");
const candidate_scanner = @import("../scoring/candidate_scanner.zig");

pub const RecoverySummary = struct {
    shards_recovered: u32,
    records_restored: u64,
    latest_generation_id: u64,
};

pub fn recoverShardRecords(
    allocator: std.mem.Allocator,
    store: *mmap_store.MmapSegmentStore,
    shard_id: u32,
    max_generation_probe: u64,
) !struct { generation: u64, records: []candidate_scanner.AlignedCandidateScanRecord } {
    var gen = max_generation_probe;
    while (gen >= 1) : (gen -= 1) {
        if (store.loadSegmentRecords(shard_id, gen)) |recs| {
            return .{ .generation = gen, .records = recs };
        } else |_| {}
        if (gen == 1) break;
    }
    const empty = try allocator.alloc(candidate_scanner.AlignedCandidateScanRecord, 0);
    return .{ .generation = 1, .records = empty };
}

pub fn verifySnapshotAndRecoverGeneration(
    snapshot_mgr: *snapshots.SnapshotManager,
    max_generation_probe: u64,
) u64 {
    var gen = max_generation_probe;
    while (gen >= 1) : (gen -= 1) {
        if (snapshot_mgr.loadSnapshotHeader(gen)) |hdr| {
            return hdr.generation_id;
        } else |_| {}
        if (gen == 1) break;
    }
    return 1;
}
