const std = @import("std");
const crawl_state = @import("crawl_state.zig");
const bloom_mod = @import("../util/bloom_filter.zig");
const binary_codec = @import("../util/binary_codec.zig");
const time_util = @import("../util/time.zig");

pub const FRONTIER_WAL_MAGIC: u32 = 0x4657414C;

pub const FrontierPartition = struct {
    allocator: std.mem.Allocator,
    partition_id: u32,
    storage_dir: []u8,
    wal_path: []u8,
    mutex: std.Thread.Mutex,
    bloom: bloom_mod.BloomFilter,
    records: std.AutoHashMap(u64, crawl_state.FrontierUrlRecord),
    sequence_id: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        partition_id: u32,
        base_storage_dir: []const u8,
        base_wal_dir: []const u8,
        expected_entries: usize,
    ) !FrontierPartition {
        var dir_buf: [512]u8 = undefined;
        const p_dir = try std.fmt.bufPrint(&dir_buf, "{s}/part_{d:0>4}", .{ base_storage_dir, partition_id });
        try std.fs.cwd().makePath(p_dir);

        var wal_buf: [512]u8 = undefined;
        try std.fs.cwd().makePath(base_wal_dir);
        const w_path = try std.fmt.bufPrint(&wal_buf, "{s}/frontier_part_{d:0>4}.wal", .{ base_wal_dir, partition_id });

        var bloom = try bloom_mod.BloomFilter.init(allocator, expected_entries, 14, 10);
        errdefer bloom.deinit();

        var part = FrontierPartition{
            .allocator = allocator,
            .partition_id = partition_id,
            .storage_dir = try allocator.dupe(u8, p_dir),
            .wal_path = try allocator.dupe(u8, w_path),
            .mutex = .{},
            .bloom = bloom,
            .records = std.AutoHashMap(u64, crawl_state.FrontierUrlRecord).init(allocator),
            .sequence_id = 0,
        };
        errdefer part.deinit();

        try part.recoverFromWal();
        return part;
    }

    pub fn deinit(self: *FrontierPartition) void {
        var it = self.records.valueIterator();
        while (it.next()) |rec| {
            rec.deinit(self.allocator);
        }
        self.records.deinit();
        self.bloom.deinit();
        self.allocator.free(self.storage_dir);
        self.allocator.free(self.wal_path);
    }

    pub fn upsertDiscovery(
        self: *FrontierPartition,
        canonical_hash: u64,
        canonical_url: []const u8,
        discovery_url: []const u8,
        domain_id: u64,
        priority: u16,
        provenance_depth: u16,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.bloom.mightContainHash(canonical_hash)) {
            if (self.records.getPtr(canonical_hash)) |existing| {
                if (std.mem.eql(u8, existing.canonical_url, canonical_url)) {
                    if (priority > existing.priority) {
                        existing.priority = priority;
                        try self.appendWalEntry(existing.*);
                    }
                    return false;
                }
            }
        }

        const now = time_util.nowMillis();
        const rec = crawl_state.FrontierUrlRecord{
            .canonical_hash = canonical_hash,
            .canonical_url = try self.allocator.dupe(u8, canonical_url),
            .discovery_url = try self.allocator.dupe(u8, discovery_url),
            .domain_id = domain_id,
            .fetch_state = .scheduled,
            .discovered_at_ms = now,
            .previous_fetch_at_ms = 0,
            .next_fetch_at_ms = now,
            .lease_expires_at_ms = 0,
            .content_fingerprint = 0,
            .http_status = 0,
            .redirect_target = try self.allocator.dupe(u8, ""),
            .retry_count = 0,
            .priority = priority,
            .provenance_depth = provenance_depth,
        };

        try self.records.put(canonical_hash, rec);
        self.bloom.insertHash(canonical_hash);
        try self.appendWalEntry(rec);
        return true;
    }

    pub fn leaseNextBatch(
        self: *FrontierPartition,
        allocator: std.mem.Allocator,
        max_items: usize,
        lease_duration_ms: u64,
    ) ![]crawl_state.FrontierUrlRecord {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = time_util.nowMillis();
        var leased = std.ArrayList(crawl_state.FrontierUrlRecord).init(allocator);
        errdefer leased.deinit();

        var it = self.records.valueIterator();
        while (it.next()) |rec| {
            if (leased.items.len >= max_items) break;
            const lease_expired = (rec.fetch_state == .leased and now >= rec.lease_expires_at_ms);
            const due = (rec.fetch_state == .scheduled or rec.fetch_state == .discovered or rec.fetch_state == .retry_wait) and (now >= rec.next_fetch_at_ms);
            if (due or lease_expired) {
                rec.fetch_state = .leased;
                rec.lease_expires_at_ms = now + lease_duration_ms;
                try self.appendWalEntry(rec.*);
                try leased.append(.{
                    .canonical_hash = rec.canonical_hash,
                    .canonical_url = try allocator.dupe(u8, rec.canonical_url),
                    .discovery_url = try allocator.dupe(u8, rec.discovery_url),
                    .domain_id = rec.domain_id,
                    .fetch_state = rec.fetch_state,
                    .discovered_at_ms = rec.discovered_at_ms,
                    .previous_fetch_at_ms = rec.previous_fetch_at_ms,
                    .next_fetch_at_ms = rec.next_fetch_at_ms,
                    .lease_expires_at_ms = rec.lease_expires_at_ms,
                    .content_fingerprint = rec.content_fingerprint,
                    .http_status = rec.http_status,
                    .redirect_target = try allocator.dupe(u8, rec.redirect_target),
                    .retry_count = rec.retry_count,
                    .priority = rec.priority,
                    .provenance_depth = rec.provenance_depth,
                });
            }
        }
        return leased.toOwnedSlice();
    }

    pub fn completeFetch(
        self: *FrontierPartition,
        canonical_hash: u64,
        new_state: crawl_state.FetchState,
        http_status: u16,
        content_fingerprint: u64,
        next_fetch_at_ms: u64,
        redirect_target: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const rec = self.records.getPtr(canonical_hash) orelse return error.NotFound;
        if (!crawl_state.FrontierUrlRecord.canTransition(rec.fetch_state, new_state)) {
            return error.InvalidStateTransition;
        }
        rec.fetch_state = new_state;
        rec.previous_fetch_at_ms = time_util.nowMillis();
        rec.next_fetch_at_ms = next_fetch_at_ms;
        rec.lease_expires_at_ms = 0;
        rec.http_status = http_status;
        rec.content_fingerprint = content_fingerprint;
        if (new_state == .retry_wait) {
            rec.retry_count +|= 1;
        } else if (new_state == .completed) {
            rec.retry_count = 0;
        }
        if (redirect_target.len > 0) {
            self.allocator.free(rec.redirect_target);
            rec.redirect_target = try self.allocator.dupe(u8, redirect_target);
        }
        try self.appendWalEntry(rec.*);
    }

    fn appendWalEntry(self: *FrontierPartition, rec: crawl_state.FrontierUrlRecord) !void {
        self.sequence_id += 1;
        var writer = binary_codec.BinaryWriter.init(self.allocator);
        defer writer.deinit();

        try writer.writeU32(FRONTIER_WAL_MAGIC);
        try writer.writeU64(self.sequence_id);
        try writer.writeU64(rec.canonical_hash);
        try writer.writeBytes(rec.canonical_url);
        try writer.writeBytes(rec.discovery_url);
        try writer.writeU64(rec.domain_id);
        try writer.writeU8(@intFromEnum(rec.fetch_state));
        try writer.writeU64(rec.discovered_at_ms);
        try writer.writeU64(rec.previous_fetch_at_ms);
        try writer.writeU64(rec.next_fetch_at_ms);
        try writer.writeU64(rec.lease_expires_at_ms);
        try writer.writeU64(rec.content_fingerprint);
        try writer.writeU16(rec.http_status);
        try writer.writeBytes(rec.redirect_target);
        try writer.writeU16(rec.retry_count);
        try writer.writeU16(rec.priority);
        try writer.writeU16(rec.provenance_depth);

        const encoded = try writer.finalizeWithCrc();
        defer self.allocator.free(encoded);

        var file = try std.fs.cwd().createFile(self.wal_path, .{ .truncate = false, .read = true });
        defer file.close();
        try file.seekFromEnd(0);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(encoded.len), .little);
        try file.writeAll(&len_bytes);
        try file.writeAll(encoded);
    }

    pub fn recoverFromWal(self: *FrontierPartition) !void {
        var file = std.fs.cwd().openFile(self.wal_path, .{}) catch return;
        defer file.close();

        while (true) {
            var len_bytes: [4]u8 = undefined;
            const n = file.readAll(&len_bytes) catch break;
            if (n < 4) break;
            const entry_len: usize = @intCast(std.mem.readInt(u32, &len_bytes, .little));
            if (entry_len == 0 or entry_len > 16 * 1024 * 1024) break;

            const buf = try self.allocator.alloc(u8, entry_len);
            defer self.allocator.free(buf);
            const rlen = file.readAll(buf) catch break;
            if (rlen != entry_len) break;

            var reader = binary_codec.BinaryReader.verifyTrailingCrc(buf) catch break;
            const magic = reader.readU32() catch break;
            if (magic != FRONTIER_WAL_MAGIC) break;
            const seq = reader.readU64() catch break;
            const chash = reader.readU64() catch break;
            const curl = reader.readBytes() catch break;
            const durl = reader.readBytes() catch break;
            const dom_id = reader.readU64() catch break;
            const fstate_raw = reader.readU8() catch break;
            const disc_ms = reader.readU64() catch break;
            const prev_ms = reader.readU64() catch break;
            const next_ms = reader.readU64() catch break;
            const lease_ms = reader.readU64() catch break;
            const fp = reader.readU64() catch break;
            const status = reader.readU16() catch break;
            const redir = reader.readBytes() catch break;
            const retries = reader.readU16() catch break;
            const prio = reader.readU16() catch break;
            const depth = reader.readU16() catch break;

            const fstate = std.meta.intToEnum(crawl_state.FetchState, fstate_raw) catch .scheduled;
            if (self.records.fetchRemove(chash)) |old_kv| {
                var old_val = old_kv.value;
                old_val.deinit(self.allocator);
            }
            const rec = crawl_state.FrontierUrlRecord{
                .canonical_hash = chash,
                .canonical_url = try self.allocator.dupe(u8, curl),
                .discovery_url = try self.allocator.dupe(u8, durl),
                .domain_id = dom_id,
                .fetch_state = if (fstate == .leased) .scheduled else fstate,
                .discovered_at_ms = disc_ms,
                .previous_fetch_at_ms = prev_ms,
                .next_fetch_at_ms = next_ms,
                .lease_expires_at_ms = lease_ms,
                .content_fingerprint = fp,
                .http_status = status,
                .redirect_target = try self.allocator.dupe(u8, redir),
                .retry_count = retries,
                .priority = prio,
                .provenance_depth = depth,
            };
            try self.records.put(chash, rec);
            self.bloom.insertHash(chash);
            if (seq > self.sequence_id) self.sequence_id = seq;
        }
    }
};
