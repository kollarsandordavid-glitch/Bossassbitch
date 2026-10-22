const std = @import("std");
const configuration = @import("configuration.zig");
const allocator_mod = @import("allocator.zig");
const scheduler = @import("scheduler.zig");
const worker_pool = @import("worker_pool.zig");
const platform = @import("../util/platform.zig");
const time_util = @import("../util/time.zig");

pub const NodeLifecycleState = enum(u8) {
    initializing = 0,
    recovering = 1,
    ready = 2,
    draining = 3,
    stopped = 4,
};

pub const RuntimeLifecycle = struct {
    backing_allocator: std.mem.Allocator,
    bounded_allocator: allocator_mod.BoundedAllocator,
    config: configuration.SystemConfiguration,
    topology: platform.HardwareTopology,
    priority_scheduler: scheduler.PriorityScheduler,
    pool: ?*worker_pool.WorkerPool,
    state: std.atomic.Value(u8),
    started_at_ms: u64,
    inflight_requests: std.atomic.Value(u64),

    pub fn init(backing_allocator: std.mem.Allocator, config_dir: []const u8, spawn_threads: bool) !*RuntimeLifecycle {
        const self = try backing_allocator.create(RuntimeLifecycle);
        errdefer backing_allocator.destroy(self);

        var cfg = try configuration.SystemConfiguration.loadFromDirectory(backing_allocator, config_dir);
        errdefer cfg.deinit();

        const bounded = allocator_mod.BoundedAllocator.init(backing_allocator, cfg.runtime.max_heap_bytes);
        const topo = platform.detectTopology();
        const sched = scheduler.PriorityScheduler.init(
            backing_allocator,
            cfg.orchestration.interactive_queue_capacity,
            cfg.orchestration.research_queue_capacity,
        );

        self.* = .{
            .backing_allocator = backing_allocator,
            .bounded_allocator = bounded,
            .config = cfg,
            .topology = topo,
            .priority_scheduler = sched,
            .pool = null,
            .state = std.atomic.Value(u8).init(@intFromEnum(NodeLifecycleState.initializing)),
            .started_at_ms = time_util.nowMillis(),
            .inflight_requests = std.atomic.Value(u64).init(0),
        };

        if (spawn_threads) {
            self.pool = try worker_pool.WorkerPool.init(
                backing_allocator,
                &self.priority_scheduler,
                self.config.runtime.worker_threads,
            );
        }
        self.state.store(@intFromEnum(NodeLifecycleState.ready), .release);
        return self;
    }

    pub fn beginRequest(self: *RuntimeLifecycle) bool {
        if (self.currentState() != .ready) return false;
        _ = self.inflight_requests.fetchAdd(1, .acq_rel);
        return true;
    }

    pub fn endRequest(self: *RuntimeLifecycle) void {
        _ = self.inflight_requests.fetchSub(1, .acq_rel);
    }

    pub fn currentState(self: *const RuntimeLifecycle) NodeLifecycleState {
        return std.meta.intToEnum(NodeLifecycleState, self.state.load(.acquire)) catch .stopped;
    }

    pub fn initiateGracefulShutdown(self: *RuntimeLifecycle) void {
        self.state.store(@intFromEnum(NodeLifecycleState.draining), .release);
        const deadline = time_util.nowMillis() + self.config.runtime.shutdown_grace_ms;
        while (self.inflight_requests.load(.acquire) > 0 and time_util.nowMillis() < deadline) {
            std.time.sleep(1_000_000);
        }
        if (self.pool) |p| {
            p.shutdownAndJoin();
            self.pool = null;
        }
        self.state.store(@intFromEnum(NodeLifecycleState.stopped), .release);
    }

    pub fn deinit(self: *RuntimeLifecycle) void {
        if (self.currentState() != .stopped) {
            self.initiateGracefulShutdown();
        }
        self.priority_scheduler.deinit();
        self.config.deinit();
        self.backing_allocator.destroy(self);
    }
};
