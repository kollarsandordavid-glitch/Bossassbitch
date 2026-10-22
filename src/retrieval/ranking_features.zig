const std = @import("std");

pub const ParetoOperatingObservation = struct {
    candidate_pool_k: u32,
    reranked_count: u32,
    observed_recall_permille: u16,
    gpu_compute_micros: u64,
    end_to_end_latency_ms: u64,
    is_pareto_efficient: bool,
};

pub const ParetoFrontierAnalyzer = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    observations: std.ArrayList(ParetoOperatingObservation),

    pub fn init(allocator: std.mem.Allocator) ParetoFrontierAnalyzer {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .observations = std.ArrayList(ParetoOperatingObservation).init(allocator),
        };
    }

    pub fn deinit(self: *ParetoFrontierAnalyzer) void {
        self.observations.deinit();
    }

    pub fn recordObservation(
        self: *ParetoFrontierAnalyzer,
        candidate_pool_k: u32,
        reranked_count: u32,
        observed_recall_permille: u16,
        gpu_compute_micros: u64,
        end_to_end_latency_ms: u64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const pareto = end_to_end_latency_ms < 100 and observed_recall_permille >= 850;
        if (self.observations.items.len >= 1024) {
            _ = self.observations.orderedRemove(0);
        }
        try self.observations.append(.{
            .candidate_pool_k = candidate_pool_k,
            .reranked_count = reranked_count,
            .observed_recall_permille = observed_recall_permille,
            .gpu_compute_micros = gpu_compute_micros,
            .end_to_end_latency_ms = end_to_end_latency_ms,
            .is_pareto_efficient = pareto,
        });
    }
};
