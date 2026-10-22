const std = @import("std");
const hashing = @import("../util/hashing.zig");
const bloom_mod = @import("../util/bloom_filter.zig");

pub const DeduplicationDecision = enum {
    unique_content,
    exact_canonical_duplicate,
    exact_content_duplicate,
    near_duplicate_template,
};

pub const DocumentSignature = struct {
    doc_id: u64,
    canonical_key_hash: u64,
    exact_content_hash: u64,
    simhash64: u64,
    shingle_sketch: [8]u64,
};

pub const DeduplicationEngine = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    shingle_width: usize,
    hamming_threshold: u32,
    canonical_bloom: bloom_mod.BloomFilter,
    canonical_to_doc: std.AutoHashMap(u64, u64),
    content_to_doc: std.AutoHashMap(u64, u64),
    signatures: std.ArrayList(DocumentSignature),
    exact_duplicates_detected: std.atomic.Value(u64),
    near_duplicates_detected: std.atomic.Value(u64),
    unique_documents_accepted: std.atomic.Value(u64),

    pub fn init(
        allocator: std.mem.Allocator,
        expected_capacity: usize,
        shingle_width: usize,
        hamming_threshold: u8,
    ) !DeduplicationEngine {
        var bloom = try bloom_mod.BloomFilter.init(allocator, expected_capacity, 14, 10);
        errdefer bloom.deinit();
        return .{
            .allocator = allocator,
            .mutex = .{},
            .shingle_width = if (shingle_width == 0) 5 else shingle_width,
            .hamming_threshold = hamming_threshold,
            .canonical_bloom = bloom,
            .canonical_to_doc = std.AutoHashMap(u64, u64).init(allocator),
            .content_to_doc = std.AutoHashMap(u64, u64).init(allocator),
            .signatures = std.ArrayList(DocumentSignature).init(allocator),
            .exact_duplicates_detected = std.atomic.Value(u64).init(0),
            .near_duplicates_detected = std.atomic.Value(u64).init(0),
            .unique_documents_accepted = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *DeduplicationEngine) void {
        self.canonical_bloom.deinit();
        self.canonical_to_doc.deinit();
        self.content_to_doc.deinit();
        self.signatures.deinit();
    }

    pub fn computeShingleSketch(text: []const u8, width: usize) [8]u64 {
        var min_hashes = [_]u64{std.math.maxInt(u64)} ** 8;
        const seeds = [8]u64{ 0x1111, 0x2222, 0x3333, 0x4444, 0x5555, 0x6666, 0x7777, 0x8888 };
        if (text.len <= width) {
            for (seeds, 0..) |s, k| {
                min_hashes[k] = hashing.wyhash64(text, s);
            }
            return min_hashes;
        }
        var i: usize = 0;
        while (i + width <= text.len) : (i += 1) {
            const shingle = text[i .. i + width];
            for (seeds, 0..) |s, k| {
                const h = hashing.wyhash64(shingle, s);
                if (h < min_hashes[k]) min_hashes[k] = h;
            }
        }
        return min_hashes;
    }

    pub fn sketchOverlapRatioPermille(a: [8]u64, b: [8]u64) u32 {
        var matches: u32 = 0;
        for (a, 0..) |va, idx| {
            if (va == b[idx]) matches += 1;
        }
        return (matches * 1000) / 8;
    }

    pub const CheckResult = struct {
        decision: DeduplicationDecision,
        matched_doc_id: u64,
        simhash: u64,
        content_hash: u64,
    };

    pub fn checkAndRegister(
        self: *DeduplicationEngine,
        doc_id: u64,
        canonical_key_hash: u64,
        body_text: []const u8,
    ) !CheckResult {
        const content_hash = hashing.wyhash64(body_text, 0x123456789abcdef0);
        const simhash = hashing.computeSimHash64(body_text, self.shingle_width);
        const sketch = computeShingleSketch(body_text, self.shingle_width);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.canonical_bloom.mightContainHash(canonical_key_hash)) {
            if (self.canonical_to_doc.get(canonical_key_hash)) |existing_id| {
                _ = self.exact_duplicates_detected.fetchAdd(1, .monotonic);
                return .{
                    .decision = .exact_canonical_duplicate,
                    .matched_doc_id = existing_id,
                    .simhash = simhash,
                    .content_hash = content_hash,
                };
            }
        }

        if (self.content_to_doc.get(content_hash)) |existing_id| {
            _ = self.exact_duplicates_detected.fetchAdd(1, .monotonic);
            return .{
                .decision = .exact_content_duplicate,
                .matched_doc_id = existing_id,
                .simhash = simhash,
                .content_hash = content_hash,
            };
        }

        for (self.signatures.items) |sig| {
            const dist = hashing.simHashHammingDistance(simhash, sig.simhash64);
            if (dist <= self.hamming_threshold) {
                const overlap = sketchOverlapRatioPermille(sketch, sig.shingle_sketch);
                if (overlap >= 625) {
                    _ = self.near_duplicates_detected.fetchAdd(1, .monotonic);
                    return .{
                        .decision = .near_duplicate_template,
                        .matched_doc_id = sig.doc_id,
                        .simhash = simhash,
                        .content_hash = content_hash,
                    };
                }
            }
        }

        self.canonical_bloom.insertHash(canonical_key_hash);
        try self.canonical_to_doc.put(canonical_key_hash, doc_id);
        try self.content_to_doc.put(content_hash, doc_id);
        try self.signatures.append(.{
            .doc_id = doc_id,
            .canonical_key_hash = canonical_key_hash,
            .exact_content_hash = content_hash,
            .simhash64 = simhash,
            .shingle_sketch = sketch,
        });
        _ = self.unique_documents_accepted.fetchAdd(1, .monotonic);

        return .{
            .decision = .unique_content,
            .matched_doc_id = doc_id,
            .simhash = simhash,
            .content_hash = content_hash,
        };
    }
};
