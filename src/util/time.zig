const std = @import("std");

pub fn nowMillis() u64 {
    const ts = std.time.milliTimestamp();
    return if (ts < 0) 0 else @intCast(ts);
}

pub fn nowMicros() u64 {
    const ts = std.time.microTimestamp();
    return if (ts < 0) 0 else @intCast(ts);
}

pub fn nowNanos() u64 {
    const ts = std.time.nanoTimestamp();
    return if (ts < 0) 0 else @intCast(ts);
}

pub const Stopwatch = struct {
    start_ns: i128,

    pub fn start() Stopwatch {
        return .{ .start_ns = std.time.nanoTimestamp() };
    }

    pub fn elapsedNanos(self: Stopwatch) u64 {
        const diff = std.time.nanoTimestamp() - self.start_ns;
        return if (diff <= 0) 0 else @intCast(diff);
    }

    pub fn elapsedMicros(self: Stopwatch) u64 {
        return self.elapsedNanos() / 1_000;
    }

    pub fn elapsedMillis(self: Stopwatch) u64 {
        return self.elapsedNanos() / 1_000_000;
    }
};
