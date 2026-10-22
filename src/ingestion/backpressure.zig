const std = @import("std");

pub const BackpressureState = enum(u8) {
    flowing = 0,
    throttled = 1,
    halted = 2,
};

pub const BackpressureController = struct {
    max_events: u64,
    max_bytes: u64,
    high_watermark_permille: u32,
    low_watermark_permille: u32,
    current_events: std.atomic.Value(u64),
    current_bytes: std.atomic.Value(u64),
    state: std.atomic.Value(u8),
    throttled_transitions: std.atomic.Value(u64),

    pub fn init(
        max_events: u32,
        max_bytes: u64,
        high_watermark_permille: u32,
        low_watermark_permille: u32,
    ) BackpressureController {
        return .{
            .max_events = @max(1, @as(u64, max_events)),
            .max_bytes = @max(1024, max_bytes),
            .high_watermark_permille = @min(990, @max(500, high_watermark_permille)),
            .low_watermark_permille = @min(800, @max(100, low_watermark_permille)),
            .current_events = std.atomic.Value(u64).init(0),
            .current_bytes = std.atomic.Value(u64).init(0),
            .state = std.atomic.Value(u8).init(@intFromEnum(BackpressureState.flowing)),
            .throttled_transitions = std.atomic.Value(u64).init(0),
        };
    }

    pub fn tryAcquire(self: *BackpressureController, event_bytes: usize) bool {
        const ev = self.current_events.load(.monotonic);
        const by = self.current_bytes.load(.monotonic);
        const add_b: u64 = @intCast(event_bytes);

        if (ev + 1 > self.max_events or by + add_b > self.max_bytes) {
            self.state.store(@intFromEnum(BackpressureState.halted), .release);
            return false;
        }

        const new_ev = self.current_events.fetchAdd(1, .acq_rel) + 1;
        const new_by = self.current_bytes.fetchAdd(add_b, .acq_rel) + add_b;

        const ev_ratio = (new_ev * 1000) / self.max_events;
        const by_ratio = (new_by * 1000) / self.max_bytes;
        const max_ratio = @max(ev_ratio, by_ratio);

        if (max_ratio >= self.high_watermark_permille) {
            const prev = self.state.swap(@intFromEnum(BackpressureState.throttled), .acq_rel);
            if (prev == @intFromEnum(BackpressureState.flowing)) {
                _ = self.throttled_transitions.fetchAdd(1, .monotonic);
            }
        }
        return true;
    }

    pub fn release(self: *BackpressureController, event_bytes: usize) void {
        const sub_b: u64 = @intCast(event_bytes);
        const prev_ev = self.current_events.fetchSub(1, .acq_rel);
        const prev_by = self.current_bytes.fetchSub(sub_b, .acq_rel);

        const rem_ev = if (prev_ev > 0) prev_ev - 1 else 0;
        const rem_by = if (prev_by >= sub_b) prev_by - sub_b else 0;

        const ev_ratio = (rem_ev * 1000) / self.max_events;
        const by_ratio = (rem_by * 1000) / self.max_bytes;
        if (@max(ev_ratio, by_ratio) <= self.low_watermark_permille) {
            self.state.store(@intFromEnum(BackpressureState.flowing), .release);
        }
    }

    pub fn currentState(self: *const BackpressureController) BackpressureState {
        return std.meta.intToEnum(BackpressureState, self.state.load(.acquire)) catch .flowing;
    }
};
