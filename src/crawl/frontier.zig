const std = @import("std");
const frontier_partition = @import("frontier_partition.zig");
const crawl_state = @import("crawl_state.zig");
const canonicalization = @import("canonicalization.zig");

pub const DistributedFrontier = struct {
    allocator: std.mem.Allocator,
    target_capacity_urls: u64,
    partitions: []frontier_partition.FrontierPartition,
    total_discovered: std.atomic.Value(u64),
    total_completed: std.atomic.Value(u64),

    pub fn init(
        allocator: std.mem.Allocator,
        partition_count: u32,
        target_capacity_urls: u64,
        storage_path: []const u8,
        wal_path: []const u8,
    ) !DistributedFrontier {
        const count: usize = @max(1, @as(usize, @intCast(partition_count)));
        var parts = try allocator.alloc(frontier_partition.FrontierPartition, count);
        var initialized: usize = 0;
        errdefer {
            for (parts[0..initialized]) |*p| p.deinit();
            allocator.free(parts);
        }

        for (0..count) |idx| {
            parts[idx] = try frontier_partition.FrontierPartition.init(
                allocator,
                @intCast(idx),
                storage_path,
                wal_path,
                4096,
            );
            initialized += 1;
        }

        return .{
            .allocator = allocator,
            .target_capacity_urls = target_capacity_urls,
            .partitions = parts,
            .total_discovered = std.atomic.Value(u64).init(0),
            .total_completed = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *DistributedFrontier) void {
        for (self.partitions) |*p| {
            p.deinit();
        }
        self.allocator.free(self.partitions);
    }

    pub fn partitionIndexForHash(self: *const DistributedFrontier, canonical_hash: u64) usize {
        return @intCast(canonical_hash % @as(u64, @intCast(self.partitions.len)));
    }

    pub fn discoverUrl(
        self: *DistributedFrontier,
        raw_url: []const u8,
        priority: u16,
        provenance_depth: u16,
    ) !bool {
        var resolved = try canonicalization.resolveCanonicalUrl(self.allocator, raw_url, null, null);
        defer resolved.deinit(self.allocator);

        const part_idx = self.partitionIndexForHash(resolved.canonical_key_hash);
        const inserted = try self.partitions[part_idx].upsertDiscovery(
            resolved.canonical_key_hash,
            resolved.canonical_url,
            raw_url,
            resolved.domain_id,
            priority,
            provenance_depth,
        );
        if (inserted) {
            _ = self.total_discovered.fetchAdd(1, .monotonic);
        }
        return inserted;
    }

    pub fn leaseDueUrls(
        self: *DistributedFrontier,
        allocator: std.mem.Allocator,
        max_total: usize,
        lease_duration_ms: u64,
    ) ![]crawl_state.FrontierUrlRecord {
        var combined = std.ArrayList(crawl_state.FrontierUrlRecord).init(allocator);
        errdefer {
            for (combined.items) |*item| item.deinit(allocator);
            combined.deinit();
        }

        for (self.partitions) |*part| {
            if (combined.items.len >= max_total) break;
            const remaining = max_total - combined.items.len;
            const batch = try part.leaseNextBatch(allocator, remaining, lease_duration_ms);
            defer allocator.free(batch);
            try combined.appendSlice(batch);
        }
        return combined.toOwnedSlice();
    }

    pub fn recordOutcome(
        self: *DistributedFrontier,
        canonical_hash: u64,
        new_state: crawl_state.FetchState,
        http_status: u16,
        content_fingerprint: u64,
        next_fetch_at_ms: u64,
        redirect_target: []const u8,
    ) !void {
        const part_idx = self.partitionIndexForHash(canonical_hash);
        try self.partitions[part_idx].completeFetch(
            canonical_hash,
            new_state,
            http_status,
            content_fingerprint,
            next_fetch_at_ms,
            redirect_target,
        );
        if (new_state == .completed) {
            _ = self.total_completed.fetchAdd(1, .monotonic);
        }
    }

    pub fn computePartitionSkewRatioPermille(self: *DistributedFrontier) u32 {
        if (self.partitions.len == 0) return 0;
        var min_count: usize = std.math.maxInt(usize);
        var max_count: usize = 0;
        var total: usize = 0;
        for (self.partitions) |*p| {
            p.mutex.lock();
            const c = p.records.count();
            p.mutex.unlock();
            if (c < min_count) min_count = c;
            if (c > max_count) max_count = c;
            total += c;
        }
        if (total == 0 or max_count == 0) return 0;
        return @intCast(((max_count - min_count) * 1000) / max_count);
    }
};
