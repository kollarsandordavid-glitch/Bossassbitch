const std = @import("std");
const hashing = @import("hashing.zig");

pub const BloomFilter = struct {
    allocator: std.mem.Allocator,
    words: []u64,
    bit_count: u64,
    hash_count: u8,
    items_inserted: u64,

    pub fn init(allocator: std.mem.Allocator, expected_items: usize, bits_per_item: usize, hash_count: u8) !BloomFilter {
        const safe_items = @max(expected_items, 64);
        const safe_bpi = @max(bits_per_item, 8);
        const raw_bits = safe_items * safe_bpi;
        const word_count = (raw_bits + 63) / 64;
        const words = try allocator.alloc(u64, word_count);
        @memset(words, 0);
        return .{
            .allocator = allocator,
            .words = words,
            .bit_count = @as(u64, @intCast(word_count)) * 64,
            .hash_count = if (hash_count == 0) 8 else hash_count,
            .items_inserted = 0,
        };
    }

    pub fn deinit(self: *BloomFilter) void {
        self.allocator.free(self.words);
    }

    pub fn clear(self: *BloomFilter) void {
        @memset(self.words, 0);
        self.items_inserted = 0;
    }

    pub fn insert(self: *BloomFilter, key: []const u8) void {
        const h1 = hashing.wyhash64(key, 0x9e3779b97f4a7c15);
        const h2 = hashing.wyhash64(key, 0xbf58476d1ce4e5b9) | 1;
        var i: u8 = 0;
        while (i < self.hash_count) : (i += 1) {
            const combined = h1 +% (@as(u64, i) *% h2);
            const bit_idx = combined % self.bit_count;
            const word_idx: usize = @intCast(bit_idx >> 6);
            const bit_offset: u6 = @intCast(bit_idx & 63);
            self.words[word_idx] |= (@as(u64, 1) << bit_offset);
        }
        self.items_inserted += 1;
    }

    pub fn insertHash(self: *BloomFilter, key_hash: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, key_hash, .little);
        self.insert(&bytes);
    }

    pub fn mightContain(self: *const BloomFilter, key: []const u8) bool {
        const h1 = hashing.wyhash64(key, 0x9e3779b97f4a7c15);
        const h2 = hashing.wyhash64(key, 0xbf58476d1ce4e5b9) | 1;
        var i: u8 = 0;
        while (i < self.hash_count) : (i += 1) {
            const combined = h1 +% (@as(u64, i) *% h2);
            const bit_idx = combined % self.bit_count;
            const word_idx: usize = @intCast(bit_idx >> 6);
            const bit_offset: u6 = @intCast(bit_idx & 63);
            if ((self.words[word_idx] & (@as(u64, 1) << bit_offset)) == 0) {
                return false;
            }
        }
        return true;
    }

    pub fn mightContainHash(self: *const BloomFilter, key_hash: u64) bool {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, key_hash, .little);
        return self.mightContain(&bytes);
    }
};
