const std = @import("std");
const invalidation = @import("invalidation.zig");
const time_util = @import("../util/time.zig");

pub const CachedRenderedEntry = struct {
    key: invalidation.CanonicalCacheKey,
    expires_at_ms: u64,
    json_payload: []u8,

    pub fn deinit(self: *CachedRenderedEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.json_payload);
    }
};

pub const RenderedResultsCache = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    max_entries: usize,
    ttl_ms: u64,
    entries: std.AutoHashMap(u64, CachedRenderedEntry),
    inflight_keys: std.AutoHashMap(u64, u32),
    hits: std.atomic.Value(u64),
    misses: std.atomic.Value(u64),
    coalesced_waits: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, max_entries: u32, ttl_sec: u64) RenderedResultsCache {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .max_entries = @max(64, @as(usize, @intCast(max_entries))),
            .ttl_ms = @max(1000, ttl_sec * 1000),
            .entries = std.AutoHashMap(u64, CachedRenderedEntry).init(allocator),
            .inflight_keys = std.AutoHashMap(u64, u32).init(allocator),
            .hits = std.atomic.Value(u64).init(0),
            .misses = std.atomic.Value(u64).init(0),
            .coalesced_waits = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *RenderedResultsCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| e.deinit(self.allocator);
        self.entries.deinit();
        self.inflight_keys.deinit();
    }

    pub fn lookupRenderedJson(
        self: *RenderedResultsCache,
        allocator: std.mem.Allocator,
        key: invalidation.CanonicalCacheKey,
        active_model_version: u32,
        active_generation: u64,
    ) !?[]u8 {
        const now = time_util.nowMillis();
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.get(key.hash64)) |entry| {
            if (entry.key.isValidForEpoch(active_model_version, active_generation) and now < entry.expires_at_ms) {
                _ = self.hits.fetchAdd(1, .monotonic);
                return try allocator.dupe(u8, entry.json_payload);
            }
            if (self.entries.fetchRemove(key.hash64)) |old_kv| {
                var old = old_kv.value;
                old.deinit(self.allocator);
            }
        }
        _ = self.misses.fetchAdd(1, .monotonic);
        return null;
    }

    pub fn storeRenderedJson(
        self: *RenderedResultsCache,
        key: invalidation.CanonicalCacheKey,
        json_payload: []const u8,
    ) !void {
        const now = time_util.nowMillis();
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.fetchRemove(key.hash64)) |old_kv| {
            var old = old_kv.value;
            old.deinit(self.allocator);
        }

        if (self.entries.count() >= self.max_entries) {
            var it = self.entries.keyIterator();
            if (it.next()) |k_ptr| {
                if (self.entries.fetchRemove(k_ptr.*)) |ev_kv| {
                    var ev = ev_kv.value;
                    ev.deinit(self.allocator);
                }
            }
        }

        try self.entries.put(key.hash64, .{
            .key = key,
            .expires_at_ms = now + self.ttl_ms,
            .json_payload = try self.allocator.dupe(u8, json_payload),
        });
    }
};
