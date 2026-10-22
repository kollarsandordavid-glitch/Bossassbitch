const std = @import("std");
const configuration = @import("../runtime/configuration.zig");
const dag_scheduler = @import("dag_scheduler.zig");
const research_pipeline = @import("research_pipeline.zig");
const gpu_scheduler = @import("gpu_scheduler.zig");
const ranking_features = @import("../retrieval/ranking_features.zig");

pub const WorkloadCoordinator = struct {
    allocator: std.mem.Allocator,
    dag: dag_scheduler.DagScheduler,
    research_mgr: research_pipeline.ResearchPipelineManager,
    gpu_sched: gpu_scheduler.GpuWorkloadScheduler,
    pareto_analyzer: ranking_features.ParetoFrontierAnalyzer,
    interactive_queries_served: std.atomic.Value(u64),
    research_jobs_served: std.atomic.Value(u64),

    pub fn init(
        allocator: std.mem.Allocator,
        orch_cfg: configuration.OrchestrationConfig,
        storage_cfg: configuration.StorageConfig,
        dag: dag_scheduler.DagScheduler,
    ) !*WorkloadCoordinator {
        const self = try allocator.create(WorkloadCoordinator);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .dag = dag,
            .research_mgr = try research_pipeline.ResearchPipelineManager.init(allocator, storage_cfg.research_state_path),
            .gpu_sched = gpu_scheduler.GpuWorkloadScheduler.init(
                allocator,
                orch_cfg.gpu_max_batch_size,
                orch_cfg.gpu_batch_window_ms,
            ),
            .pareto_analyzer = ranking_features.ParetoFrontierAnalyzer.init(allocator),
            .interactive_queries_served = std.atomic.Value(u64).init(0),
            .research_jobs_served = std.atomic.Value(u64).init(0),
        };
        return self;
    }

    pub fn deinit(self: *WorkloadCoordinator) void {
        self.pareto_analyzer.deinit();
        self.gpu_sched.deinit();
        self.research_mgr.deinit();
        self.allocator.destroy(self);
    }
};
