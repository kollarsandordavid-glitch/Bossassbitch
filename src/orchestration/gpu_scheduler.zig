const std = @import("std");
const time_util = @import("../util/time.zig");

pub const GpuWorkloadClass = enum(u8) {
    interactive_query_embed = 0,
    interactive_rerank = 1,
    priority_document_embed = 2,
    batch_ingestion_embed = 3,
    background_research = 4,
    model_training_step = 5,
};

pub const QueuedGpuRequest = struct {
    request_id: u64,
    workload_class: GpuWorkloadClass,
    enqueued_at_ms: u64,
    batch_items: u32,
};

pub const GpuWorkloadScheduler = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    max_batch_size: u32,
    batch_window_ms: u64,
    interactive_queue: std.ArrayList(QueuedGpuRequest),
    background_queue: std.ArrayList(QueuedGpuRequest),
    next_request_id: std.atomic.Value(u64),
    total_interactive_dispatched: std.atomic.Value(u64),
    total_background_dispatched: std.atomic.Value(u64),
    last_queue_delay_ms: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, max_batch_size: u32, batch_window_ms: u64) GpuWorkloadScheduler {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .max_batch_size = @max(1, max_batch_size),
            .batch_window_ms = batch_window_ms,
            .interactive_queue = std.ArrayList(QueuedGpuRequest).init(allocator),
            .background_queue = std.ArrayList(QueuedGpuRequest).init(allocator),
            .next_request_id = std.atomic.Value(u64).init(1),
            .total_interactive_dispatched = std.atomic.Value(u64).init(0),
            .total_background_dispatched = std.atomic.Value(u64).init(0),
            .last_queue_delay_ms = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *GpuWorkloadScheduler) void {
        self.interactive_queue.deinit();
        self.background_queue.deinit();
    }

    pub fn enqueueWorkload(self: *GpuWorkloadScheduler, class: GpuWorkloadClass, batch_items: u32) !u64 {
        const req_id = self.next_request_id.fetchAdd(1, .monotonic);
        const now = time_util.nowMillis();
        const item = QueuedGpuRequest{
            .request_id = req_id,
            .workload_class = class,
            .enqueued_at_ms = now,
            .batch_items = batch_items,
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        switch (class) {
            .interactive_query_embed, .interactive_rerank => {
                try self.interactive_queue.append(item);
                _ = self.total_interactive_dispatched.fetchAdd(1, .monotonic);
            },
            else => {
                try self.background_queue.append(item);
                _ = self.total_background_dispatched.fetchAdd(1, .monotonic);
            },
        }
        return req_id;
    }

    pub fn drainNextBatch(self: *GpuWorkloadScheduler) u32 {
        const now = time_util.nowMillis();
        self.mutex.lock();
        defer self.mutex.unlock();

        var drained_items: u32 = 0;
        while (self.interactive_queue.items.len > 0 and drained_items < self.max_batch_size) {
            const req = self.interactive_queue.orderedRemove(0);
            drained_items += req.batch_items;
            self.last_queue_delay_ms.store(now -| req.enqueued_at_ms, .monotonic);
        }

        if (drained_items == 0) {
            while (self.background_queue.items.len > 0 and drained_items < self.max_batch_size) {
                const req = self.background_queue.orderedRemove(0);
                drained_items += req.batch_items;
                self.last_queue_delay_ms.store(now -| req.enqueued_at_ms, .monotonic);
            }
        }
        return drained_items;
    }
};
