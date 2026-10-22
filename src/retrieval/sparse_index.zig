const std = @import("std");
const hashing = @import("../util/hashing.zig");

pub const FieldKind = enum(u8) {
    title = 0,
    heading = 1,
    body = 2,
    url = 3,
    anchor = 4,
    metadata = 5,
};

pub const TermPostingEntry = struct {
    doc_id: u64,
    title_tf: u16,
    heading_tf: u16,
    body_tf: u16,
    url_tf: u16,
    anchor_tf: u16,
    metadata_tf: u16,
};

pub const SparseInvertedIndex = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    postings: std.AutoHashMap(u64, std.ArrayList(TermPostingEntry)),
    doc_lengths: std.AutoHashMap(u64, u32),
    total_docs: u64,
    total_body_tokens: u64,

    pub fn init(allocator: std.mem.Allocator) SparseInvertedIndex {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .postings = std.AutoHashMap(u64, std.ArrayList(TermPostingEntry)).init(allocator),
            .doc_lengths = std.AutoHashMap(u64, u32).init(allocator),
            .total_docs = 0,
            .total_body_tokens = 0,
        };
    }

    pub fn deinit(self: *SparseInvertedIndex) void {
        var it = self.postings.valueIterator();
        while (it.next()) |list| list.deinit();
        self.postings.deinit();
        self.doc_lengths.deinit();
    }

    pub fn indexDocumentFields(
        self: *SparseInvertedIndex,
        doc_id: u64,
        title: []const u8,
        body: []const u8,
        url: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var field_counts = std.AutoHashMap(u64, TermPostingEntry).init(self.allocator);
        defer field_counts.deinit();

        _ = try accumulateFieldTokens(&field_counts, doc_id, title, .title);
        _ = try accumulateFieldTokens(&field_counts, doc_id, url, .url);
        const body_toks = try accumulateFieldTokens(&field_counts, doc_id, body, .body);

        var cit = field_counts.iterator();
        while (cit.next()) |kv| {
            const gop = try self.postings.getOrPut(kv.key_ptr.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(TermPostingEntry).init(self.allocator);
            }
            var updated_existing = false;
            for (gop.value_ptr.items) |*entry| {
                if (entry.doc_id == doc_id) {
                    entry.* = kv.value_ptr.*;
                    updated_existing = true;
                    break;
                }
            }
            if (!updated_existing) {
                try gop.value_ptr.append(kv.value_ptr.*);
            }
        }

        if (!self.doc_lengths.contains(doc_id)) {
            self.total_docs += 1;
        }
        try self.doc_lengths.put(doc_id, body_toks);
        self.total_body_tokens += body_toks;
    }

    pub fn averageDocLength(self: *const SparseInvertedIndex) f32 {
        if (self.total_docs == 0) return 100.0;
        return @max(1.0, @as(f32, @floatFromInt(self.total_body_tokens)) / @as(f32, @floatFromInt(self.total_docs)));
    }
};

fn accumulateFieldTokens(
    map: *std.AutoHashMap(u64, TermPostingEntry),
    doc_id: u64,
    text: []const u8,
    field: FieldKind,
) !u32 {
    var count: u32 = 0;
    var iter = std.mem.tokenizeAny(u8, text, " \t\r\n,.;:!?()[]{}<>\"'/-_");
    while (iter.next()) |raw| {
        if (raw.len == 0) continue;
        count += 1;
        var lower: [64]u8 = undefined;
        const len = @min(raw.len, lower.len);
        for (raw[0..len], 0..) |ch, idx| {
            lower[idx] = std.ascii.toLower(ch);
        }
        const h = hashing.wyhash64(lower[0..len], 0x7265747269657665);
        const gop = try map.getOrPut(h);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .doc_id = doc_id,
                .title_tf = 0,
                .heading_tf = 0,
                .body_tf = 0,
                .url_tf = 0,
                .anchor_tf = 0,
                .metadata_tf = 0,
            };
        }
        switch (field) {
            .title => gop.value_ptr.title_tf +|= 1,
            .heading => gop.value_ptr.heading_tf +|= 1,
            .body => gop.value_ptr.body_tf +|= 1,
            .url => gop.value_ptr.url_tf +|= 1,
            .anchor => gop.value_ptr.anchor_tf +|= 1,
            .metadata => gop.value_ptr.metadata_tf +|= 1,
        }
    }
    return count;
}
