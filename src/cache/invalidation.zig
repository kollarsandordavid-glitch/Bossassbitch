const std = @import("std");
const hashing = @import("../util/hashing.zig");

pub const CanonicalCacheKey = struct {
    hash64: u64,
    model_version: u32,
    index_generation: u64,

    pub fn build(
        query_text: []const u8,
        ranking_mode: []const u8,
        top_k: u32,
        filter_hash: u64,
        model_version: u32,
        index_generation: u64,
    ) CanonicalCacheKey {
        var buf: [512]u8 = undefined;
        const written = std.fmt.bufPrint(
            &buf,
            "q={s}|m={s}|k={d}|f={d}|mv={d}|ig={d}",
            .{ query_text, ranking_mode, top_k, filter_hash, model_version, index_generation },
        ) catch query_text;
        return .{
            .hash64 = hashing.wyhash64(written, 0x63616368656b6579),
            .model_version = model_version,
            .index_generation = index_generation,
        };
    }

    pub fn isValidForEpoch(self: CanonicalCacheKey, active_model_version: u32, active_generation: u64) bool {
        return self.model_version == active_model_version and self.index_generation == active_generation;
    }
};

pub const CacheEpochTracker = struct {
    active_model_version: std.atomic.Value(u32),
    active_index_generation: std.atomic.Value(u64),
    invalidation_events: std.atomic.Value(u64),

    pub fn init(model_version: u32, index_generation: u64) CacheEpochTracker {
        return .{
            .active_model_version = std.atomic.Value(u32).init(model_version),
            .active_index_generation = std.atomic.Value(u64).init(index_generation),
            .invalidation_events = std.atomic.Value(u64).init(0),
        };
    }

    pub fn invalidateOnGenerationAdvance(self: *CacheEpochTracker, new_generation: u64) void {
        self.active_index_generation.store(new_generation, .release);
        _ = self.invalidation_events.fetchAdd(1, .monotonic);
    }

    pub fn invalidateOnModelRollout(self: *CacheEpochTracker, new_model_version: u32) void {
        self.active_model_version.store(new_model_version, .release);
        _ = self.invalidation_events.fetchAdd(1, .monotonic);
    }
};
