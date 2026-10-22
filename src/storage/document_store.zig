const std = @import("std");
const binary_codec = @import("../util/binary_codec.zig");
const compression = @import("../util/compression.zig");

pub const DOC_RECORD_MAGIC: u32 = 0x43444F43;

pub const StoredDocumentRecord = struct {
    doc_id: u64,
    canonical_url: []u8,
    original_url: []u8,
    title: []u8,
    description: []u8,
    body_text: []u8,
    language: []u8,
    domain_id: u64,
    content_hash: u64,
    simhash: u64,
    published_at_ms: u64,
    fetched_at_ms: u64,
    quality_permille: u16,

    pub fn deinit(self: *StoredDocumentRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_url);
        allocator.free(self.original_url);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.body_text);
        allocator.free(self.language);
    }

    pub fn clone(self: StoredDocumentRecord, allocator: std.mem.Allocator) !StoredDocumentRecord {
        return .{
            .doc_id = self.doc_id,
            .canonical_url = try allocator.dupe(u8, self.canonical_url),
            .original_url = try allocator.dupe(u8, self.original_url),
            .title = try allocator.dupe(u8, self.title),
            .description = try allocator.dupe(u8, self.description),
            .body_text = try allocator.dupe(u8, self.body_text),
            .language = try allocator.dupe(u8, self.language),
            .domain_id = self.domain_id,
            .content_hash = self.content_hash,
            .simhash = self.simhash,
            .published_at_ms = self.published_at_ms,
            .fetched_at_ms = self.fetched_at_ms,
            .quality_permille = self.quality_permille,
        };
    }
};

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    storage_dir: []u8,
    log_path: []u8,
    mutex: std.Thread.Mutex,
    documents: std.AutoHashMap(u64, StoredDocumentRecord),

    pub fn init(allocator: std.mem.Allocator, storage_dir: []const u8) !DocumentStore {
        try std.fs.cwd().makePath(storage_dir);
        var path_buf: [512]u8 = undefined;
        const lpath = try std.fmt.bufPrint(&path_buf, "{s}/canonical_documents.bin", .{storage_dir});

        var store = DocumentStore{
            .allocator = allocator,
            .storage_dir = try allocator.dupe(u8, storage_dir),
            .log_path = try allocator.dupe(u8, lpath),
            .mutex = .{},
            .documents = std.AutoHashMap(u64, StoredDocumentRecord).init(allocator),
        };
        errdefer store.deinit();
        try store.recoverFromDisk();
        return store;
    }

    pub fn deinit(self: *DocumentStore) void {
        var it = self.documents.valueIterator();
        while (it.next()) |rec| rec.deinit(self.allocator);
        self.documents.deinit();
        self.allocator.free(self.log_path);
        self.allocator.free(self.storage_dir);
    }

    pub fn putDocument(self: *DocumentStore, rec: StoredDocumentRecord) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const compressed_body = try compression.compressByteBlock(self.allocator, rec.body_text);
        defer self.allocator.free(compressed_body);

        var writer = binary_codec.BinaryWriter.init(self.allocator);
        defer writer.deinit();

        try writer.writeU32(DOC_RECORD_MAGIC);
        try writer.writeU64(rec.doc_id);
        try writer.writeBytes(rec.canonical_url);
        try writer.writeBytes(rec.original_url);
        try writer.writeBytes(rec.title);
        try writer.writeBytes(rec.description);
        try writer.writeBytes(compressed_body);
        try writer.writeBytes(rec.language);
        try writer.writeU64(rec.domain_id);
        try writer.writeU64(rec.content_hash);
        try writer.writeU64(rec.simhash);
        try writer.writeU64(rec.published_at_ms);
        try writer.writeU64(rec.fetched_at_ms);
        try writer.writeU16(rec.quality_permille);

        const encoded = try writer.finalizeWithCrc();
        defer self.allocator.free(encoded);

        var file = try std.fs.cwd().createFile(self.log_path, .{ .truncate = false, .read = true });
        defer file.close();
        try file.seekFromEnd(0);

        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(encoded.len), .little);
        try file.writeAll(&len_bytes);
        try file.writeAll(encoded);
        try file.sync();

        if (self.documents.fetchRemove(rec.doc_id)) |old_kv| {
            var old = old_kv.value;
            old.deinit(self.allocator);
        }
        const cloned = try rec.clone(self.allocator);
        try self.documents.put(rec.doc_id, cloned);
    }

    pub fn getDocumentCopy(self: *DocumentStore, allocator: std.mem.Allocator, doc_id: u64) !?StoredDocumentRecord {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.documents.get(doc_id)) |rec| {
            return try rec.clone(allocator);
        }
        return null;
    }

    pub fn count(self: *DocumentStore) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.documents.count();
    }

    pub fn recoverFromDisk(self: *DocumentStore) !void {
        var file = std.fs.cwd().openFile(self.log_path, .{}) catch return;
        defer file.close();

        while (true) {
            var len_bytes: [4]u8 = undefined;
            const n = file.readAll(&len_bytes) catch break;
            if (n < 4) break;
            const entry_len: usize = @intCast(std.mem.readInt(u32, &len_bytes, .little));
            if (entry_len == 0 or entry_len > 32 * 1024 * 1024) break;

            const buf = try self.allocator.alloc(u8, entry_len);
            defer self.allocator.free(buf);
            const r = file.readAll(buf) catch break;
            if (r != entry_len) break;

            var reader = binary_codec.BinaryReader.verifyTrailingCrc(buf) catch break;
            const magic = reader.readU32() catch break;
            if (magic != DOC_RECORD_MAGIC) break;

            const doc_id = reader.readU64() catch break;
            const curl = reader.readBytes() catch break;
            const ourl = reader.readBytes() catch break;
            const title = reader.readBytes() catch break;
            const desc = reader.readBytes() catch break;
            const comp_body = reader.readBytes() catch break;
            const lang = reader.readBytes() catch break;
            const dom_id = reader.readU64() catch break;
            const chash = reader.readU64() catch break;
            const shash = reader.readU64() catch break;
            const pub_ms = reader.readU64() catch break;
            const fet_ms = reader.readU64() catch break;
            const qual = reader.readU16() catch break;

            const decomp_body = compression.decompressByteBlock(self.allocator, comp_body) catch break;
            errdefer self.allocator.free(decomp_body);

            if (self.documents.fetchRemove(doc_id)) |old_kv| {
                var old = old_kv.value;
                old.deinit(self.allocator);
            }

            try self.documents.put(doc_id, .{
                .doc_id = doc_id,
                .canonical_url = try self.allocator.dupe(u8, curl),
                .original_url = try self.allocator.dupe(u8, ourl),
                .title = try self.allocator.dupe(u8, title),
                .description = try self.allocator.dupe(u8, desc),
                .body_text = decomp_body,
                .language = try self.allocator.dupe(u8, lang),
                .domain_id = dom_id,
                .content_hash = chash,
                .simhash = shash,
                .published_at_ms = pub_ms,
                .fetched_at_ms = fet_ms,
                .quality_permille = qual,
            });
        }
    }
};
