const std = @import("std");
const domain_velocity = @import("domain_velocity.zig");

pub const RecrawlScheduleDecision = struct {
    next_fetch_at_ms: u64,
    interval_sec: u64,
    updated_priority: u16,
};

pub const RecrawlScheduler = struct {
    min_interval_sec: u64,
    default_interval_sec: u64,
    max_interval_sec: u64,
    velocity_tracker: *domain_velocity.DomainVelocityTracker,

    pub fn init(
        min_interval_sec: u64,
        default_interval_sec: u64,
        max_interval_sec: u64,
        velocity_tracker: *domain_velocity.DomainVelocityTracker,
    ) RecrawlScheduler {
        return .{
            .min_interval_sec = @max(60, min_interval_sec),
            .default_interval_sec = @max(300, default_interval_sec),
            .max_interval_sec = @max(3600, max_interval_sec),
            .velocity_tracker = velocity_tracker,
        };
    }

    pub fn computeNextSchedule(
        self: *RecrawlScheduler,
        domain_id: u64,
        url: []const u8,
        content_changed: bool,
        now_ms: u64,
    ) !RecrawlScheduleDecision {
        const stats = try self.velocity_tracker.recordFetchObservation(
            domain_id,
            url,
            content_changed,
            now_ms,
        );

        var interval_sec: u64 = switch (stats.category) {
            .breaking_news_or_funding => self.min_interval_sec,
            .preprint_repository => self.min_interval_sec * 2,
            .active_dynamic => self.default_interval_sec / 6,
            .standard_web => self.default_interval_sec,
            .stable_archive => self.max_interval_sec,
        };

        if (stats.ema_change_rate_permille >= 800) {
            interval_sec = @max(self.min_interval_sec, interval_sec / 4);
        } else if (stats.ema_change_rate_permille <= 100) {
            interval_sec = @min(self.max_interval_sec, interval_sec * 3);
        }

        const priority: u16 = switch (stats.category) {
            .breaking_news_or_funding => 950,
            .preprint_repository => 900,
            .active_dynamic => 750,
            .standard_web => 500,
            .stable_archive => 150,
        };

        return .{
            .next_fetch_at_ms = now_ms + (interval_sec * 1000),
            .interval_sec = interval_sec,
            .updated_priority = priority,
        };
    }
};
