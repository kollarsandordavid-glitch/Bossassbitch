const std = @import("std");
const checksums = @import("../util/checksums.zig");

pub const METADATA_RECORD_MAGIC: u32 = 0x4D544452;

pub const RankingMetadataRecord = struct {
    doc_id: u64,
    authority_permille: u16,
    originality_permille: u16,
    citation_count: u32,
    inbound_domain_diversity: u16,
    updated_at_ms: u64,
};

pub const MetadataStore = struct {
    allocator: std.mem.Allocator,
    storage_dir: []u8,
    log_path: []u8,
    mutex: std.Thread.Mutex,
    records: std.AutoHashMap(u64, RankingMetadataRecord),

    pub fn init(allocator: std.mem.Allocator, storage_dir: []const u8) !MetadataStore {
        try std.fs.cwd().makePath(storage_dir);
        const dir_copy = try allocator.dupe(u8, storage_dir);
        errdefer allocator.free(dir_copy);
        const log_path = try std.fmt.allocPrint(allocator, "{s}/ranking_metadata.bin", .{storage_dir});
        errdefer allocator.free(log_path);

        var store = MetadataStore{
            .allocator = allocator,
            .storage_dir = dir_copy,
            .log_path = log_path,
            .mutex = .{},
            .records = std.AutoHashMap(u64, RankingMetadataRecord).init(allocator),
        };
        errdefer store.records.deinit();

        try store.replayFromDisk();
        return store;
    }

    pub fn deinit(self: *MetadataStore) void {
        self.records.deinit();
        self.allocator.free(self.log_path);
        self.allocator.free(self.storage_dir);
    }

    pub fn upsertRankingMetadata(self: *MetadataStore, rec: RankingMetadataRecord) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.appendRecordToDisk(rec);
        try self.records.put(rec.doc_id, rec);
    }

    pub fn getRankingMetadata(self: *MetadataStore, doc_id: u64) ?RankingMetadataRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.records.get(doc_id);
    }

    fn appendRecordToDisk(self: *MetadataStore, rec: RankingMetadataRecord) !void {
        var file = try std.fs.cwd().createFile(self.log_path, .{ .truncate = false, .read = true });
        defer file.close();
        try file.seekFromEnd(0);

        var payload: [26]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], rec.doc_id, .little);
        std.mem.writeInt(u16, payload[8..10], rec.authority_permille, .little);
        std.mem.writeInt(u16, payload[10..12], rec.originality_permille, .little);
        std.mem.writeInt(u32, payload[12..16], rec.citation_count, .little);
        std.mem.writeInt(u16, payload[16..18], rec.inbound_domain_diversity, .little);
        std.mem.writeInt(u64, payload[18..26], rec.updated_at_ms, .little);

        const crc = checksums.crc32(&payload);
        var frame: [34]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], METADATA_RECORD_MAGIC, .little);
        std.mem.writeInt(u32, frame[4..8], crc, .little);
        @memcpy(frame[8..34], &payload);
        try file.writeAll(&frame);
    }

    fn replayFromDisk(self: *MetadataStore) !void {
        const file = std.fs.cwd().openFile(self.log_path, .{}) catch return;
        defer file.close();

        var frame: [34]u8 = undefined;
        while (true) {
            const n = try file.readAll(&frame);
            if (n < frame.len) break;
            const magic = std.mem.readInt(u32, frame[0..4], .little);
            if (magic != METADATA_RECORD_MAGIC) break;
            const expected_crc = std.mem.readInt(u32, frame[4..8], .little);
            const payload = frame[8..34];
            if (!checksums.verifyCrc32(payload, expected_crc)) break;

            const rec = RankingMetadataRecord{
                .doc_id = std.mem.readInt(u64, payload[0..8], .little),
                .authority_permille = std.mem.readInt(u16, payload[8..10], .little),
                .originality_permille = std.mem.readInt(u16, payload[10..12], .little),
                .citation_count = std.mem.readInt(u32, payload[12..16], .little),
                .inbound_domain_diversity = std.mem.readInt(u16, payload[16..18], .little),
                .updated_at_ms = std.mem.readInt(u64, payload[18..26], .little),
            };
            try self.records.put(rec.doc_id, rec);
        }
    }
};
