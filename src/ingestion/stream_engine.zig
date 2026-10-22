const std = @import("std");
const configuration = @import("../runtime/configuration.zig");
const event_codec = @import("event_codec.zig");
const wal_mod = @import("write_ahead_log.zig");
const partition_router = @import("partition_router.zig");
const backpressure = @import("backpressure.zig");
const content_filter = @import("content_filter.zig");
const hashing = @import("../util/hashing.zig");

pub const StreamEngine = struct {
    allocator: std.mem.Allocator,
    router: partition_router.PartitionRouter,
    wals: []wal_mod.IngestionWal,
    bp: backpressure.BackpressureController,
    filter: content_filter.ContentFilter,
    published_events: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, cfg: configuration.IngestionConfig) !*StreamEngine {
        const self = try allocator.create(StreamEngine);
        errdefer allocator.destroy(self);

        const pcount: usize = @max(1, @as(usize, @intCast(cfg.stream_partitions)));
        var wals = try allocator.alloc(wal_mod.IngestionWal, pcount);
        var init_count: usize = 0;
        errdefer {
            for (wals[0..init_count]) |*w| w.deinit();
            allocator.free(wals);
        }

        for (0..pcount) |idx| {
            wals[idx] = try wal_mod.IngestionWal.init(allocator, cfg.wal_dir, @intCast(idx));
            init_count += 1;
        }

        self.* = .{
            .allocator = allocator,
            .router = partition_router.PartitionRouter.init(cfg.stream_partitions),
            .wals = wals,
            .bp = backpressure.BackpressureController.init(
                cfg.max_in_memory_events,
                cfg.max_queue_bytes,
                cfg.backpressure_high_watermark_permille,
                cfg.backpressure_low_watermark_permille,
            ),
            .filter = content_filter.ContentFilter.init(
                @intCast(cfg.spam_probability_threshold_permille),
                @intCast(cfg.min_quality_score_permille),
                cfg.min_text_bytes,
            ),
            .published_events = std.atomic.Value(u64).init(0),
        };
        return self;
    }

    pub fn deinit(self: *StreamEngine) void {
        for (self.wals) |*w| w.deinit();
        self.allocator.free(self.wals);
        self.allocator.destroy(self);
    }

    pub fn publishDocumentEvent(
        self: *StreamEngine,
        doc_id: u64,
        domain_id: u64,
        canonical_url: []const u8,
        title: []const u8,
        body_text: []const u8,
        language: []const u8,
        published_at_ms: u64,
        quality_score_permille: u16,
        spam_probability_permille: u16,
        priority_flag: bool,
    ) !u64 {
        const est_bytes = canonical_url.len + title.len + body_text.len + 64;
        if (!self.bp.tryAcquire(est_bytes)) {
            return error.QueueCapacityExceeded;
        }
        defer self.bp.release(est_bytes);

        const idem_key = hashing.wyhash64(canonical_url, doc_id ^ hashing.wyhash64(body_text, 0x77));
        const part_id = self.router.routeByCanonicalUrl(canonical_url);

        var ev = event_codec.IngestionEvent{
            .sequence_id = 0,
            .idempotency_key = idem_key,
            .doc_id = doc_id,
            .domain_id = domain_id,
            .canonical_url = try self.allocator.dupe(u8, canonical_url),
            .title = try self.allocator.dupe(u8, title),
            .body_text = try self.allocator.dupe(u8, body_text),
            .language = try self.allocator.dupe(u8, language),
            .published_at_ms = published_at_ms,
            .quality_score_permille = quality_score_permille,
            .spam_probability_permille = spam_probability_permille,
            .priority_flag = priority_flag,
        };
        defer ev.deinit(self.allocator);

        const seq = try self.wals[part_id].appendIdempotent(&ev);
        _ = self.published_events.fetchAdd(1, .monotonic);
        return seq;
    }
};
