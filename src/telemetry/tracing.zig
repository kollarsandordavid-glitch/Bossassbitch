const std = @import("std");
const time_util = @import("../util/time.zig");

pub const TraceSpanRecord = struct {
    trace_id: u64,
    span_id: u64,
    branch_name: []const u8,
    started_at_micros: u64,
    duration_micros: u64,
    candidate_count: u32,
    cache_hit: bool,
};

pub const DistributedTracer = struct {
    ring_buffer: [1024]TraceSpanRecord,
    write_cursor: std.atomic.Value(u64),
    sample_permille: u32,

    pub fn init(sample_permille: u32) DistributedTracer {
        var tr: DistributedTracer = undefined;
        for (0..1024) |i| {
            tr.ring_buffer[i] = .{
                .trace_id = 0,
                .span_id = 0,
                .branch_name = "idle",
                .started_at_micros = 0,
                .duration_micros = 0,
                .candidate_count = 0,
                .cache_hit = false,
            };
        }
        tr.write_cursor = std.atomic.Value(u64).init(0);
        tr.sample_permille = sample_permille;
        return tr;
    }

    pub fn recordSpan(
        self: *DistributedTracer,
        trace_id: u64,
        branch_name: []const u8,
        duration_micros: u64,
        candidate_count: u32,
        cache_hit: bool,
    ) void {
        if ((trace_id % 1000) >= self.sample_permille) return;
        const idx = self.write_cursor.fetchAdd(1, .monotonic);
        const slot: usize = @intCast(idx & 1023);
        self.ring_buffer[slot] = .{
            .trace_id = trace_id,
            .span_id = idx + 1,
            .branch_name = branch_name,
            .started_at_micros = time_util.nowMicros(),
            .duration_micros = duration_micros,
            .candidate_count = candidate_count,
            .cache_hit = cache_hit,
        };
    }
};
