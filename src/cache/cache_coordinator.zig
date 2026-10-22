const std = @import("std");
const configuration = @import("../runtime/configuration.zig");
const invalidation = @import("invalidation.zig");
const query_embeddings = @import("query_embeddings.zig");
const cluster_postings = @import("cluster_postings.zig");
const rendered_results = @import("rendered_results.zig");

pub const HierarchicalCacheCoordinator = struct {
    allocator: std.mem.Allocator,
    epoch: invalidation.CacheEpochTracker,
    embedding_cache: query_embeddings.QueryEmbeddingCache,
    posting_cache: cluster_postings.ClusterPostingsCache,
    response_cache: rendered_results.RenderedResultsCache,

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: configuration.CacheConfig,
        initial_model_version: u32,
        initial_generation: u64,
    ) !*HierarchicalCacheCoordinator {
        const self = try allocator.create(HierarchicalCacheCoordinator);
        self.* = .{
            .allocator = allocator,
            .epoch = invalidation.CacheEpochTracker.init(initial_model_version, initial_generation),
            .embedding_cache = query_embeddings.QueryEmbeddingCache.init(
                allocator,
                cfg.query_embedding_cache_entries,
                cfg.query_embedding_ttl_sec,
            ),
            .posting_cache = cluster_postings.ClusterPostingsCache.init(
                allocator,
                cfg.cluster_posting_cache_bytes,
                cfg.cluster_posting_ttl_sec,
            ),
            .response_cache = rendered_results.RenderedResultsCache.init(
                allocator,
                cfg.rendered_response_cache_entries,
                cfg.rendered_response_ttl_sec,
            ),
        };
        return self;
    }

    pub fn deinit(self: *HierarchicalCacheCoordinator) void {
        self.response_cache.deinit();
        self.posting_cache.deinit();
        self.embedding_cache.deinit();
        self.allocator.destroy(self);
    }

    pub fn notifyIndexGenerationUpdate(self: *HierarchicalCacheCoordinator, new_generation: u64) void {
        self.epoch.invalidateOnGenerationAdvance(new_generation);
    }

    pub fn notifyModelRollout(self: *HierarchicalCacheCoordinator, new_model_version: u32) void {
        self.epoch.invalidateOnModelRollout(new_model_version);
        self.embedding_cache.purgeInvalidModelVersions(new_model_version);
    }
};
