const std = @import("std");
const scheduler = @import("scheduler.zig");
const time_util = @import("../util/time.zig");

pub const WorkerPool = struct {
    allocator: std.mem.Allocator,
    sched: *scheduler.PriorityScheduler,
    threads: []std.Thread,
    running: std.atomic.Value(bool),
    active_workers: std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator, sched: *scheduler.PriorityScheduler, thread_count: u32) !*WorkerPool {
        const safe_count: usize = @max(1, @as(usize, @intCast(thread_count)));
        const self = try allocator.create(WorkerPool);
        errdefer allocator.destroy(self);
        const threads = try allocator.alloc(std.Thread, safe_count);
        errdefer allocator.free(threads);

        self.* = .{
            .allocator = allocator,
            .sched = sched,
            .threads = threads,
            .running = std.atomic.Value(bool).init(true),
            .active_workers = std.atomic.Value(u32).init(0),
        };

        for (self.threads, 0..) |*t, idx| {
            t.* = try std.Thread.spawn(.{}, workerLoop, .{ self, idx });
        }
        return self;
    }

    pub fn shutdownAndJoin(self: *WorkerPool) void {
        self.running.store(false, .release);
        for (self.threads) |t| {
            t.join();
        }
        self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }

    fn workerLoop(self: *WorkerPool, worker_idx: usize) void {
        _ = worker_idx;
        while (self.running.load(.acquire)) {
            const now = time_util.nowMillis();
            if (self.sched.popNext(now)) |task| {
                _ = self.active_workers.fetchAdd(1, .monotonic);
                task.execute_fn(task.context);
                _ = self.active_workers.fetchSub(1, .monotonic);
            } else {
                std.time.sleep(500_000);
            }
        }
    }
};
