const std = @import("std");
const cancellation = @import("cancellation.zig");
const errors = @import("errors.zig");

pub const TaskPriority = enum(u8) {
    background = 0,
    research = 1,
    ingestion = 2,
    interactive_search = 3,
};

pub const ScheduledTask = struct {
    id: u64,
    priority: TaskPriority,
    enqueued_at_ms: u64,
    deadline_ms: u64,
    token: ?*cancellation.CancellationToken,
    context: *anyopaque,
    execute_fn: *const fn (ctx: *anyopaque) void,
};

pub const PriorityScheduler = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    queues: [4]std.ArrayList(ScheduledTask),
    max_capacity_per_priority: [4]usize,
    total_enqueued: std.atomic.Value(u64),
    total_executed: std.atomic.Value(u64),
    total_dropped_deadline: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, interactive_cap: usize, research_cap: usize) PriorityScheduler {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .queues = .{
                std.ArrayList(ScheduledTask).init(allocator),
                std.ArrayList(ScheduledTask).init(allocator),
                std.ArrayList(ScheduledTask).init(allocator),
                std.ArrayList(ScheduledTask).init(allocator),
            },
            .max_capacity_per_priority = .{
                research_cap,
                research_cap,
                interactive_cap,
                interactive_cap,
            },
            .total_enqueued = std.atomic.Value(u64).init(0),
            .total_executed = std.atomic.Value(u64).init(0),
            .total_dropped_deadline = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *PriorityScheduler) void {
        for (&self.queues) |*q| {
            q.deinit();
        }
    }

    pub fn submit(self: *PriorityScheduler, task: ScheduledTask) errors.EngineError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const idx: usize = @intFromEnum(task.priority);
        if (self.queues[idx].items.len >= self.max_capacity_per_priority[idx]) {
            return error.QueueCapacityExceeded;
        }
        self.queues[idx].append(task) catch return error.OutOfMemory;
        _ = self.total_enqueued.fetchAdd(1, .monotonic);
    }

    pub fn popNext(self: *PriorityScheduler, now_ms: u64) ?ScheduledTask {
        self.mutex.lock();
        defer self.mutex.unlock();

        var p: usize = 4;
        while (p > 0) {
            p -= 1;
            var q = &self.queues[p];
            while (q.items.len > 0) {
                const candidate = q.orderedRemove(0);
                if (now_ms >= candidate.deadline_ms) {
                    _ = self.total_dropped_deadline.fetchAdd(1, .monotonic);
                    continue;
                }
                if (candidate.token) |tok| {
                    if (tok.isCancelled()) {
                        _ = self.total_dropped_deadline.fetchAdd(1, .monotonic);
                        continue;
                    }
                }
                _ = self.total_executed.fetchAdd(1, .monotonic);
                return candidate;
            }
        }
        return null;
    }

    pub fn runPendingBatch(self: *PriorityScheduler, max_tasks: usize, now_ms: u64) usize {
        var ran: usize = 0;
        while (ran < max_tasks) : (ran += 1) {
            const task = self.popNext(now_ms) orelse break;
            task.execute_fn(task.context);
        }
        return ran;
    }
};
