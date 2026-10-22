const std = @import("std");
const time_util = @import("../util/time.zig");
const errors = @import("errors.zig");

pub const CancellationReason = enum(u8) {
    none = 0,
    explicit_cancel = 1,
    deadline_expired = 2,
    sufficient_candidates = 3,
    parent_cancelled = 4,
    system_shutdown = 5,
};

pub const CancellationToken = struct {
    cancelled_flag: std.atomic.Value(u8),
    deadline_ms: u64,
    parent: ?*const CancellationToken,

    pub fn initWithDeadline(timeout_ms: u64, parent: ?*const CancellationToken) CancellationToken {
        const now = time_util.nowMillis();
        var effective_deadline = now +| timeout_ms;
        if (parent) |p| {
            if (p.deadline_ms < effective_deadline) {
                effective_deadline = p.deadline_ms;
            }
        }
        return .{
            .cancelled_flag = std.atomic.Value(u8).init(@intFromEnum(CancellationReason.none)),
            .deadline_ms = effective_deadline,
            .parent = parent,
        };
    }

    pub fn cancel(self: *CancellationToken, reason: CancellationReason) void {
        const val = if (reason == .none) @intFromEnum(CancellationReason.explicit_cancel) else @intFromEnum(reason);
        self.cancelled_flag.store(val, .release);
    }

    pub fn checkReason(self: *const CancellationToken) CancellationReason {
        const local_raw = self.cancelled_flag.load(.acquire);
        if (local_raw != 0) {
            return std.meta.intToEnum(CancellationReason, local_raw) catch .explicit_cancel;
        }
        if (self.parent) |p| {
            const p_reason = p.checkReason();
            if (p_reason != .none) return .parent_cancelled;
        }
        if (time_util.nowMillis() >= self.deadline_ms) {
            return .deadline_expired;
        }
        return .none;
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.checkReason() != .none;
    }

    pub fn remainingMillis(self: *const CancellationToken) u64 {
        const now = time_util.nowMillis();
        if (now >= self.deadline_ms) return 0;
        return self.deadline_ms - now;
    }

    pub fn throwIfCancelled(self: *const CancellationToken) errors.EngineError!void {
        switch (self.checkReason()) {
            .none => return,
            .deadline_expired => return error.DeadlineExceeded,
            else => return error.OperationCancelled,
        }
    }
};
