const std = @import("std");
const compression = @import("../util/compression.zig");

pub const CompressedPostingList = struct {
    allocator: std.mem.Allocator,
    doc_ids: std.ArrayList(u64),
    compressed_cache: ?[]u8,
    dirty: bool,

    pub fn init(allocator: std.mem.Allocator) CompressedPostingList {
        return .{
            .allocator = allocator,
            .doc_ids = std.ArrayList(u64).init(allocator),
            .compressed_cache = null,
            .dirty = false,
        };
    }

    pub fn deinit(self: *CompressedPostingList) void {
        if (self.compressed_cache) |c| self.allocator.free(c);
        self.doc_ids.deinit();
    }

    pub fn addDocId(self: *CompressedPostingList, doc_id: u64) !void {
        if (self.doc_ids.items.len > 0 and self.doc_ids.items[self.doc_ids.items.len - 1] == doc_id) {
            return;
        }
        try self.doc_ids.append(doc_id);
        self.dirty = true;
    }

    pub fn ensureCompressed(self: *CompressedPostingList) ![]const u8 {
        if (!self.dirty) {
            if (self.compressed_cache) |c| return c;
        }
        std.mem.sort(u64, self.doc_ids.items, {}, std.sort.asc(u64));
        if (self.compressed_cache) |old| self.allocator.free(old);
        self.compressed_cache = try compression.compressDeltaU64(self.allocator, self.doc_ids.items);
        self.dirty = false;
        return self.compressed_cache.?;
    }

    pub fn intersectSorted(
        allocator: std.mem.Allocator,
        list_a: []const u64,
        list_b: []const u64,
    ) ![]u64 {
        var out = std.ArrayList(u64).init(allocator);
        errdefer out.deinit();
        var i: usize = 0;
        var j: usize = 0;
        while (i < list_a.len and j < list_b.len) {
            if (list_a[i] == list_b[j]) {
                try out.append(list_a[i]);
                i += 1;
                j += 1;
            } else if (list_a[i] < list_b[j]) {
                i += 1;
            } else {
                j += 1;
            }
        }
        return out.toOwnedSlice();
    }
};
