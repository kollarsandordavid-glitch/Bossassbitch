const std = @import("std");
const configuration = @import("../runtime/configuration.zig");
const frontier_mod = @import("frontier.zig");
const fetcher_mod = @import("fetcher.zig");
const browser_runtime = @import("browser_runtime.zig");
const deduplication = @import("deduplication.zig");
const document_extractor = @import("document_extractor.zig");
const domain_velocity = @import("domain_velocity.zig");
const recrawl_scheduler = @import("recrawl_scheduler.zig");
const time_util = @import("../util/time.zig");

pub const CrawlCoordinator = struct {
    allocator: std.mem.Allocator,
    frontier: frontier_mod.DistributedFrontier,
    fetcher: fetcher_mod.CrawlerFetcher,
    browser_pool: browser_runtime.BrowserRuntimePool,
    dedup: deduplication.DeduplicationEngine,
    velocity: domain_velocity.DomainVelocityTracker,
    scheduler: recrawl_scheduler.RecrawlScheduler,
    extractor: document_extractor.DocumentExtractor,
    lease_duration_ms: u64,

    pub fn init(allocator: std.mem.Allocator, cfg: configuration.CrawlerConfig) !*CrawlCoordinator {
        const self = try allocator.create(CrawlCoordinator);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.frontier = try frontier_mod.DistributedFrontier.init(
            allocator,
            cfg.frontier_partitions,
            cfg.target_frontier_capacity_urls,
            cfg.frontier_storage_path,
            cfg.wal_storage_path,
        );
        errdefer self.frontier.deinit();

        self.fetcher = fetcher_mod.CrawlerFetcher.init(
            allocator,
            cfg.user_agent,
            @intCast(cfg.max_response_bytes),
            cfg.connect_timeout_ms,
            cfg.max_redirects,
        );
        errdefer self.fetcher.deinit();

        self.browser_pool = browser_runtime.BrowserRuntimePool.init(
            allocator,
            cfg.browser_pool_size,
            cfg.browser_render_deadline_ms,
            @intCast(cfg.max_response_bytes),
        );

        self.dedup = try deduplication.DeduplicationEngine.init(
            allocator,
            65536,
            cfg.shingle_width,
            cfg.simhash_hamming_threshold,
        );
        errdefer self.dedup.deinit();

        self.velocity = domain_velocity.DomainVelocityTracker.init(allocator);
        errdefer self.velocity.deinit();

        self.scheduler = recrawl_scheduler.RecrawlScheduler.init(
            cfg.min_recrawl_interval_sec,
            cfg.default_recrawl_interval_sec,
            cfg.max_recrawl_interval_sec,
            &self.velocity,
        );

        self.extractor = document_extractor.DocumentExtractor.init(
            allocator,
            @intCast(cfg.dom_max_depth),
            cfg.dom_max_nodes,
            &self.browser_pool,
            &self.dedup,
        );
        self.lease_duration_ms = cfg.lease_duration_ms;
        return self;
    }

    pub fn deinit(self: *CrawlCoordinator) void {
        self.velocity.deinit();
        self.dedup.deinit();
        self.fetcher.deinit();
        self.frontier.deinit();
        self.allocator.destroy(self);
    }

    pub fn ingestHtmlPageDirectly(
        self: *CrawlCoordinator,
        url: []const u8,
        html_content: []const u8,
    ) !document_extractor.ExtractedCanonicalDocument {
        _ = try self.frontier.discoverUrl(url, 800, 0);
        var doc = try self.extractor.extractFromHtml(url, null, html_content);
        errdefer doc.deinit(self.allocator);

        const now = time_util.nowMillis();
        const sched = try self.scheduler.computeNextSchedule(
            doc.domain_id,
            doc.canonical_url,
            doc.dedup_decision == .unique_content,
            now,
        );

        try self.frontier.recordOutcome(
            doc.canonical_key_hash,
            .completed,
            200,
            doc.content_hash,
            sched.next_fetch_at_ms,
            "",
        );

        for (doc.outbound_links) |link| {
            if (std.mem.startsWith(u8, link.target_url, "http://") or
                std.mem.startsWith(u8, link.target_url, "https://"))
            {
                _ = self.frontier.discoverUrl(link.target_url, 400, 1) catch {};
            }
        }
        return doc;
    }
};
