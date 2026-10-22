const std = @import("std");

pub const DomainVelocityCategory = enum(u8) {
    breaking_news_or_funding = 0,
    preprint_repository = 1,
    active_dynamic = 2,
    standard_web = 3,
    stable_archive = 4,
};

pub const DomainStats = struct {
    domain_id: u64,
    total_fetches: u64,
    content_changes: u64,
    ema_change_rate_permille: u32,
    last_change_timestamp_ms: u64,
    last_fetch_timestamp_ms: u64,
    category: DomainVelocityCategory,
};

pub const DomainVelocityTracker = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    domains: std.AutoHashMap(u64, DomainStats),

    pub fn init(allocator: std.mem.Allocator) DomainVelocityTracker {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .domains = std.AutoHashMap(u64, DomainStats).init(allocator),
        };
    }

    pub fn deinit(self: *DomainVelocityTracker) void {
        self.domains.deinit();
    }

    pub fn classifyUrlCategory(url: []const u8) DomainVelocityCategory {
        if (std.ascii.indexOfIgnoreCase(url, "arxiv.org") != null or
            std.ascii.indexOfIgnoreCase(url, "biorxiv.org") != null or
            std.ascii.indexOfIgnoreCase(url, "preprint") != null)
        {
            return .preprint_repository;
        }
        if (std.ascii.indexOfIgnoreCase(url, "funding") != null or
            std.ascii.indexOfIgnoreCase(url, "press") != null or
            std.ascii.indexOfIgnoreCase(url, "news") != null or
            std.ascii.indexOfIgnoreCase(url, "announce") != null)
        {
            return .breaking_news_or_funding;
        }
        if (std.ascii.indexOfIgnoreCase(url, "archive") != null or
            std.ascii.indexOfIgnoreCase(url, "/201") != null or
            std.ascii.indexOfIgnoreCase(url, "/200") != null)
        {
            return .stable_archive;
        }
        return .standard_web;
    }

    pub fn recordFetchObservation(
        self: *DomainVelocityTracker,
        domain_id: u64,
        url: []const u8,
        content_changed: bool,
        now_ms: u64,
    ) !DomainStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        const observed_cat = classifyUrlCategory(url);
        const sample_permille: u32 = if (content_changed) 1000 else 0;

        if (self.domains.getPtr(domain_id)) |stats| {
            stats.total_fetches += 1;
            if (content_changed) {
                stats.content_changes += 1;
                stats.last_change_timestamp_ms = now_ms;
            }
            stats.ema_change_rate_permille = (stats.ema_change_rate_permille * 7 + sample_permille * 3) / 10;
            stats.last_fetch_timestamp_ms = now_ms;
            if (@intFromEnum(observed_cat) < @intFromEnum(stats.category)) {
                stats.category = observed_cat;
            } else if (stats.ema_change_rate_permille >= 750) {
                stats.category = .breaking_news_or_funding;
            } else if (stats.ema_change_rate_permille <= 50 and stats.total_fetches >= 10) {
                stats.category = .stable_archive;
            }
            return stats.*;
        } else {
            const initial = DomainStats{
                .domain_id = domain_id,
                .total_fetches = 1,
                .content_changes = if (content_changed) 1 else 0,
                .ema_change_rate_permille = if (content_changed) 700 else 300,
                .last_change_timestamp_ms = if (content_changed) now_ms else 0,
                .last_fetch_timestamp_ms = now_ms,
                .category = observed_cat,
            };
            try self.domains.put(domain_id, initial);
            return initial;
        }
    }
};
