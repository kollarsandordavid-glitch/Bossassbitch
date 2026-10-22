const std = @import("std");
const time_util = @import("../util/time.zig");

pub const CachedClusterPostingEntry = struct {
    centroid_id: u32,
    index_generation: u64,
    expires_at_ms: u64,
    doc_ids: []u64,

    pub fn deinit(self: *CachedClusterPostingEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.doc_ids);
    }
};

pub const ClusterPostingsCache = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    max_bytes: u64,
    current_bytes: u64,
    ttl_ms: u64,
    entries: std.AutoHashMap(u32, CachedClusterPostingEntry),
    hits: std.atomic.Value(u64),
    misses: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, max_bytes: u64, ttl_sec: u64) ClusterPostingsCache {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .max_bytes = @max(65536, max_bytes),
            .current_bytes = 0,
            .ttl_ms = @max(1000, ttl_sec * 1000),
            .entries = std.AutoHashMap(u32, CachedClusterPostingEntry).init(allocator),
            .hits = std.atomic.Value(u64).init(0),
            .misses = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *ClusterPostingsCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| e.deinit(self.allocator);
        self.entries.deinit();
    }

    pub fn getDocIdsCopy(
        self: *ClusterPostingsCache,
        allocator: std.mem.Allocator,
        centroid_id: u32,
        active_generation: u64,
    ) !?[]u64 {
        const now = time_util.nowMillis();
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.get(centroid_id)) |entry| {
            if (entry.index_generation == active_generation and now < entry.expires_at_ms) {
                _ = self.hits.fetchAdd(1, .monotonic);
                return try allocator.dupe(u64, entry.doc_ids);
            }
        }
        _ = self.misses.fetchAdd(1, .monotonic);
        return null;
    }

    pub fn putClusterDocIds(
        self: *ClusterPostingsCache,
        centroid_id: u32,
        index_generation: u64,
        doc_ids: []const u64,
    ) !void {
        const entry_bytes: u64 = @intCast(doc_ids.len * @sizeOf(u64) + 32);
        if (entry_bytes > self.max_bytes) return;
        const now = time_util.nowMillis();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.fetchRemove(centroid_id)) |old_kv| {
            var old = old_kv.value;
            self.current_bytes -|= @intCast(old.doc_ids.len * @sizeOf(u64) + 32);
            old.deinit(self.allocator);
        }

        while (self.current_bytes + entry_bytes > self.max_bytes and self.entries.count() > 0) {
            var it = self.entries.keyIterator();
            if (it.next()) |k_ptr| {
                if (self.entries.fetchRemove(k_ptr.*)) |evicted_kv| {
                    var ev = evicted_kv.value;
                    self.current_bytes -|= @intCast(ev.doc_ids.len * @sizeOf(u64) + 32);
                    ev.deinit(self.allocator);
                }
            } else break;
        }

        const duped = try self.allocator.dupe(u64, doc_ids);
        try self.entries.put(centroid_id, .{
            .centroid_id = centroid_id,
            .index_generation = index_generation,
            .expires_at_ms = now + self.ttl_ms,
            .doc_ids = duped,
        });
        self.current_bytes += entry_bytes;
    }
};
