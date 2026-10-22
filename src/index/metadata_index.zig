const std = @import("std");
const posting_lists = @import("posting_lists.zig");
const bloom_mod = @import("../util/bloom_filter.zig");
const hashing = @import("../util/hashing.zig");

pub const DocumentMetadataAttributes = struct {
    doc_id: u64,
    domain_hash32: u32,
    language_hash32: u32,
    doc_type_hash32: u32,
    published_at_ms: u64,
    quality_permille: u16,
};

pub const MetadataIndex = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    domain_postings: std.AutoHashMap(u32, posting_lists.CompressedPostingList),
    language_postings: std.AutoHashMap(u32, posting_lists.CompressedPostingList),
    doctype_postings: std.AutoHashMap(u32, posting_lists.CompressedPostingList),
    domain_bloom: bloom_mod.BloomFilter,
    doc_attributes: std.AutoHashMap(u64, DocumentMetadataAttributes),

    pub fn init(allocator: std.mem.Allocator) !MetadataIndex {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .domain_postings = std.AutoHashMap(u32, posting_lists.CompressedPostingList).init(allocator),
            .language_postings = std.AutoHashMap(u32, posting_lists.CompressedPostingList).init(allocator),
            .doctype_postings = std.AutoHashMap(u32, posting_lists.CompressedPostingList).init(allocator),
            .domain_bloom = try bloom_mod.BloomFilter.init(allocator, 8192, 12, 8),
            .doc_attributes = std.AutoHashMap(u64, DocumentMetadataAttributes).init(allocator),
        };
    }

    pub fn deinit(self: *MetadataIndex) void {
        var dit = self.domain_postings.valueIterator();
        while (dit.next()) |pl| pl.deinit();
        self.domain_postings.deinit();

        var lit = self.language_postings.valueIterator();
        while (lit.next()) |pl| pl.deinit();
        self.language_postings.deinit();

        var tit = self.doctype_postings.valueIterator();
        while (tit.next()) |pl| pl.deinit();
        self.doctype_postings.deinit();

        self.domain_bloom.deinit();
        self.doc_attributes.deinit();
    }

    pub fn hashAttr32(value: []const u8) u32 {
        var lower: [128]u8 = undefined;
        const len = @min(value.len, lower.len);
        for (value[0..len], 0..) |ch, i| {
            lower[i] = std.ascii.toLower(ch);
        }
        return @truncate(hashing.wyhash64(lower[0..len], 0x3141592653589793));
    }

    pub fn indexDocumentMetadata(
        self: *MetadataIndex,
        doc_id: u64,
        domain: []const u8,
        language: []const u8,
        doc_type: []const u8,
        published_at_ms: u64,
        quality_permille: u16,
    ) !DocumentMetadataAttributes {
        const dom_h = hashAttr32(domain);
        const lang_h = hashAttr32(language);
        const type_h = hashAttr32(doc_type);

        self.mutex.lock();
        defer self.mutex.unlock();

        self.domain_bloom.insertHash(dom_h);
        try addToPostingMap(self.allocator, &self.domain_postings, dom_h, doc_id);
        try addToPostingMap(self.allocator, &self.language_postings, lang_h, doc_id);
        try addToPostingMap(self.allocator, &self.doctype_postings, type_h, doc_id);

        const attrs = DocumentMetadataAttributes{
            .doc_id = doc_id,
            .domain_hash32 = dom_h,
            .language_hash32 = lang_h,
            .doc_type_hash32 = type_h,
            .published_at_ms = published_at_ms,
            .quality_permille = quality_permille,
        };
        try self.doc_attributes.put(doc_id, attrs);
        return attrs;
    }
};

fn addToPostingMap(
    allocator: std.mem.Allocator,
    map: *std.AutoHashMap(u32, posting_lists.CompressedPostingList),
    key: u32,
    doc_id: u64,
) !void {
    const gop = try map.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = posting_lists.CompressedPostingList.init(allocator);
    }
    try gop.value_ptr.addDocId(doc_id);
}
