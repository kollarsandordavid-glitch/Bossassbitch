const std = @import("std");
const configuration = @import("../runtime/configuration.zig");
const training_runtime = @import("training_runtime.zig");
const negative_mining = @import("negative_mining.zig");
const drift_detection = @import("drift_detection.zig");
const graph_quality = @import("graph_quality.zig");
const checkpoint = @import("../models/checkpoint.zig");
const checkpoint_transfer = @import("checkpoint_transfer.zig");
const model_version = @import("../models/model_version.zig");
const time_util = @import("../util/time.zig");

pub const TrainingCoordinator = struct {
    allocator: std.mem.Allocator,
    runtime: training_runtime.TrainingRuntime,
    miner: negative_mining.HardNegativeMiner,
    drift: drift_detection.OutOfDistributionDriftDetector,
    graph_analyzer: graph_quality.LinkGraphQualityAnalyzer,
    ckpt_mgr: checkpoint.CheckpointManager,
    transfer: checkpoint_transfer.CheckpointTransferClient,
    active_model_version: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        train_cfg: configuration.TrainingConfig,
        model_cfg: configuration.ModelConfig,
    ) !*TrainingCoordinator {
        const self = try allocator.create(TrainingCoordinator);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.runtime = try training_runtime.TrainingRuntime.init(
            allocator,
            train_cfg.production_b300_gpu_count,
            train_cfg.global_batch_size,
        );
        errdefer self.runtime.deinit();

        self.miner = negative_mining.HardNegativeMiner.init(
            allocator,
            train_cfg.hard_negative_pool_capacity,
            train_cfg.max_negative_model_version_lag,
        );
        errdefer self.miner.deinit();

        self.drift = drift_detection.OutOfDistributionDriftDetector.init(
            allocator,
            train_cfg.drift_recalibration_threshold_milli,
        );
        self.graph_analyzer = graph_quality.LinkGraphQualityAnalyzer.init(allocator);
        self.ckpt_mgr = try checkpoint.CheckpointManager.init(allocator, model_cfg.checkpoint_dir);
        errdefer self.ckpt_mgr.deinit();

        self.transfer = checkpoint_transfer.CheckpointTransferClient.init(allocator, &self.ckpt_mgr);
        self.active_model_version = model_cfg.model_version;
        return self;
    }

    pub fn deinit(self: *TrainingCoordinator) void {
        self.ckpt_mgr.deinit();
        self.miner.deinit();
        self.runtime.deinit();
        self.allocator.destroy(self);
    }

    pub fn runTrainingIterationAndCheckpoint(self: *TrainingCoordinator) !training_runtime.TrainingStepMetrics {
        const step_idx = self.runtime.curr.global_step + 1;
        const now_ms = time_util.nowMillis();
        for (0..8) |idx| {
            const doc_id: u64 = step_idx * 100 + idx + 1;
            const sim: f32 = 0.55 - @as(f32, @floatFromInt(idx)) * 0.07;
            var emb: [256]f32 = undefined;
            for (0..256) |c| {
                emb[c] = @sin(@as(f32, @floatFromInt((idx + 1) * (c + 3))) * 0.13);
            }
            _ = try self.miner.enqueueCandidate(.{
                .query_hash = step_idx,
                .negative_doc_id = doc_id,
                .model_version = self.active_model_version,
                .index_generation = 1,
                .scoring_version = 1,
                .retrieved_at_ms = now_ms,
                .similarity_score = sim,
                .pool_weight = 1.0,
                .retained_embedding = emb,
            }, self.active_model_version);
        }

        const mined = try self.miner.selectFreshNegatives(self.allocator, self.active_model_version, 6);
        defer self.allocator.free(mined);

        var neg_sims_buf: [6]f32 = [_]f32{ 0.42, 0.35, 0.28, 0.19, 0.11, -0.05 };
        for (mined, 0..) |m, idx| {
            if (idx < neg_sims_buf.len) {
                neg_sims_buf[idx] = m.similarity_score;
            }
        }

        var batch_embs: [4][256]f32 = undefined;
        for (0..4) |r| {
            for (0..256) |c| {
                const seed_f: f32 = @floatFromInt((r + 1) * (c + 3) + @as(usize, @intCast(step_idx % 97)));
                batch_embs[r][c] = @sin(seed_f * 0.17);
            }
        }

        const metrics = self.runtime.executeStep(0.86, &neg_sims_buf, &batch_embs);
        const desc = model_version.ModelVersionDescriptor{
            .model_version = self.active_model_version,
            .learned_temperature = metrics.learned_temperature,
        };
        _ = try self.transfer.persistAndPublishCheckpoint(
            desc,
            metrics.curriculum_stage,
            metrics.global_step,
            self.runtime.weights,
            self.runtime.opt.m,
        );
        return metrics;
    }
};
