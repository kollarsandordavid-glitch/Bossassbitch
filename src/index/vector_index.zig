const std = @import("std");
const configuration = @import("../runtime/configuration.zig");
const centroid_manager = @import("centroid_manager.zig");
const shard_manager = @import("shard_manager.zig");
const metadata_index = @import("metadata_index.zig");
const filter_engine = @import("filter_engine.zig");
const deletion_manager = @import("deletion_manager.zig");
const mmap_store = @import("mmap_store.zig");
const nvme_store = @import("nvme_store.zig");
const consistency = @import("consistency.zig");
const replication = @import("replication.zig");
const snapshots = @import("snapshots.zig");
const candidate_scanner = @import("../scoring/candidate_scanner.zig");

pub const DistributedVectorIndex = struct {
    allocator: std.mem.Allocator,
    centroids: centroid_manager.CentroidManager,
    shards: shard_manager.ShardManager,
    meta_idx: metadata_index.MetadataIndex,
    deletions: deletion_manager.DeletionManager,
    segment_store: mmap_store.MmapSegmentStore,
    primary_store: nvme_store.NvmePrimaryVectorStore,
    consistency_coord: consistency.ConsistencyCoordinator,
    repl_mgr: replication.ShardReplicationManager,
    snapshot_mgr: snapshots.SnapshotManager,
    total_indexed_docs: std.atomic.Value(u64),

    pub fn init(
        allocator: std.mem.Allocator,
        vec_cfg: configuration.VectorIndexConfig,
        model_version: u32,
    ) !*DistributedVectorIndex {
        const self = try allocator.create(DistributedVectorIndex);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.centroids = centroid_manager.CentroidManager.init(
            allocator,
            vec_cfg.semantic_centroids,
            vec_cfg.cluster_split_threshold,
            vec_cfg.centroid_drift_threshold_milli,
        );
        errdefer self.centroids.deinit();

        self.shards = try shard_manager.ShardManager.init(
            allocator,
            vec_cfg.shard_count,
            vec_cfg.semantic_centroids,
        );
        errdefer self.shards.deinit();

        self.meta_idx = try metadata_index.MetadataIndex.init(allocator);
        errdefer self.meta_idx.deinit();

        self.deletions = deletion_manager.DeletionManager.init(allocator);
        errdefer self.deletions.deinit();

        self.segment_store = try mmap_store.MmapSegmentStore.init(allocator, vec_cfg.index_storage_path);
        errdefer self.segment_store.deinit();

        self.primary_store = try nvme_store.NvmePrimaryVectorStore.init(allocator, vec_cfg.index_storage_path);
        errdefer self.primary_store.deinit();

        self.consistency_coord = consistency.ConsistencyCoordinator.init(1, model_version, 2, 1);
        self.repl_mgr = replication.ShardReplicationManager.init(allocator, vec_cfg.replication_factor);
        errdefer self.repl_mgr.deinit();

        self.snapshot_mgr = try snapshots.SnapshotManager.init(allocator, vec_cfg.snapshot_storage_path);
        errdefer self.snapshot_mgr.deinit();

        self.total_indexed_docs = std.atomic.Value(u64).init(0);
        return self;
    }

    pub fn deinit(self: *DistributedVectorIndex) void {
        self.snapshot_mgr.deinit();
        self.repl_mgr.deinit();
        self.primary_store.deinit();
        self.segment_store.deinit();
        self.deletions.deinit();
        self.meta_idx.deinit();
        self.shards.deinit();
        self.centroids.deinit();
        self.allocator.destroy(self);
    }

    pub fn indexDocumentVector(
        self: *DistributedVectorIndex,
        doc_id: u64,
        model_version: u32,
        primary_4096: *const [4096]f32,
        packed_binary_32: *const [32]u8,
        original_norm: f32,
        domain: []const u8,
        language: []const u8,
        doc_type: []const u8,
        published_at_ms: u64,
        quality_permille: u16,
    ) !u32 {
        const centroid_id = try self.centroids.assignDocumentToCentroid(packed_binary_32);
        const meta_attrs = try self.meta_idx.indexDocumentMetadata(
            doc_id,
            domain,
            language,
            doc_type,
            published_at_ms,
            quality_permille,
        );
        try self.primary_store.storePrimaryVector4096(doc_id, model_version, primary_4096);

        const rec = candidate_scanner.AlignedCandidateScanRecord{
            .packed_binary = packed_binary_32.*,
            .doc_id = doc_id,
            .original_norm = original_norm,
            .centroid_id = centroid_id,
            .published_at_ms = published_at_ms,
            .domain_hash32 = meta_attrs.domain_hash32,
            .quality_permille = quality_permille,
            .flags = 0,
        };

        const shard_id = try self.shards.insertRecord(rec);
        const seq = self.consistency_coord.advanceCommitSequence();
        const gen = self.consistency_coord.active_generation.load(.acquire);
        try self.repl_mgr.appendMutation(seq, gen, shard_id, doc_id, false);
        _ = self.total_indexed_docs.fetchAdd(1, .monotonic);
        return centroid_id;
    }

    pub fn refreshAndPublishGeneration(self: *DistributedVectorIndex, model_version: u32) !consistency.VisibilityBoundary {
        const boundary = self.consistency_coord.publishNewGeneration(model_version);
        _ = try self.shards.compactAllShards(&self.segment_store, &self.deletions, boundary.generation_id);
        _ = try self.snapshot_mgr.createSnapshotManifest(
            boundary.generation_id,
            boundary.commit_sequence,
            boundary.model_version,
            self.total_indexed_docs.load(.monotonic),
            self.deletions.tombstone_count.load(.monotonic),
            @intCast(self.shards.shards.len),
        );
        return boundary;
    }

    pub fn filterEngine(self: *DistributedVectorIndex) filter_engine.FilterEngine {
        return filter_engine.FilterEngine.init(&self.meta_idx);
    }
};
