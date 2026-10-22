const std = @import("std");
const time_util = @import("../util/time.zig");

pub const LivePublishCadence = struct {
    hourly_interval_ms: u64,
    priority_interval_ms: u64,
    last_hourly_publish_ms: u64,
    last_priority_publish_ms: u64,
    pending_standard_docs: u64,
    pending_priority_docs: u64,
    published_generations: u64,

    pub fn init(hourly_sec: u64, priority_sec: u64) LivePublishCadence {
        const now = time_util.nowMillis();
        return .{
            .hourly_interval_ms = @max(1000, hourly_sec * 1000),
            .priority_interval_ms = @max(100, priority_sec * 1000),
            .last_hourly_publish_ms = now,
            .last_priority_publish_ms = now,
            .pending_standard_docs = 0,
            .pending_priority_docs = 0,
            .published_generations = 1,
        };
    }

    pub fn recordStagedDocument(self: *LivePublishCadence, is_priority: bool) void {
        if (is_priority) {
            self.pending_priority_docs += 1;
        } else {
            self.pending_standard_docs += 1;
        }
    }

    pub fn shouldPublishNow(self: *const LivePublishCadence, now_ms: u64) bool {
        if (self.pending_priority_docs > 0 and now_ms >= self.last_priority_publish_ms + self.priority_interval_ms) {
            return true;
        }
        if ((self.pending_standard_docs + self.pending_priority_docs) > 0 and
            now_ms >= self.last_hourly_publish_ms + self.hourly_interval_ms)
        {
            return true;
        }
        return false;
    }

    pub fn markPublished(self: *LivePublishCadence, now_ms: u64) u64 {
        self.pending_standard_docs = 0;
        self.pending_priority_docs = 0;
        self.last_priority_publish_ms = now_ms;
        self.last_hourly_publish_ms = now_ms;
        self.published_generations += 1;
        return self.published_generations;
    }
};
