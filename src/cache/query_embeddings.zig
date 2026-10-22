const std = @import("std");
const hashing = @import("../util/hashing.zig");
const time_util = @import("../util/time.zig");

pub const CachedQueryEmbedding = struct {
    query_hash: u64,
    model_version: u32,
    expires_at_ms: u64,
    retained_embedding: [256]f32,
    packed_binary: [32]u8,
    original_norm: f32,
};

pub const QueryEmbeddingCache = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    max_entries: usize,
    ttl_ms: u64,
    entries: std.AutoHashMap(u64, CachedQueryEmbedding),
    hits: std.atomic.Value(u64),
    misses: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, max_entries: u32, ttl_sec: u64) QueryEmbeddingCache {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .max_entries = @max(64, @as(usize, @intCast(max_entries))),
            .ttl_ms = @max(1000, ttl_sec * 1000),
            .entries = std.AutoHashMap(u64, CachedQueryEmbedding).init(allocator),
            .hits = std.atomic.Value(u64).init(0),
            .misses = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *QueryEmbeddingCache) void {
        self.entries.deinit();
    }

    pub fn get(
        self: *QueryEmbeddingCache,
        query_text: []const u8,
        active_model_version: u32,
    ) ?CachedQueryEmbedding {
        const q_hash = hashing.wyhash64(query_text, active_model_version);
        const now = time_util.nowMillis();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.get(q_hash)) |entry| {
            if (entry.model_version == active_model_version and now < entry.expires_at_ms) {
                _ = self.hits.fetchAdd(1, .monotonic);
                return entry;
            }
            _ = self.entries.remove(q_hash);
        }
        _ = self.misses.fetchAdd(1, .monotonic);
        return null;
    }

    pub fn put(
        self: *QueryEmbeddingCache,
        query_text: []const u8,
        model_version: u32,
        retained: *const [256]f32,
        packed_bin: *const [32]u8,
        orig_norm: f32,
    ) !void {
        const q_hash = hashing.wyhash64(query_text, model_version);
        const now = time_util.nowMillis();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.count() >= self.max_entries) {
            var it = self.entries.keyIterator();
            if (it.next()) |first_k| {
                _ = self.entries.remove(first_k.*);
            }
        }

        try self.entries.put(q_hash, .{
            .query_hash = q_hash,
            .model_version = model_version,
            .expires_at_ms = now + self.ttl_ms,
            .retained_embedding = retained.*,
            .packed_binary = packed_bin.*,
            .original_norm = orig_norm,
        });
    }

    pub fn purgeInvalidModelVersions(self: *QueryEmbeddingCache, active_model_version: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var to_del = std.ArrayList(u64).init(self.allocator);
        defer to_del.deinit();
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.model_version != active_model_version) {
                to_del.append(kv.key_ptr.*) catch break;
            }
        }
        for (to_del.items) |k| {
            _ = self.entries.remove(k);
        }
    }
};
