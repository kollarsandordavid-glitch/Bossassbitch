const std = @import("std");
const temperature_scaling = @import("temperature_scaling.zig");
const contrastive_loss = @import("contrastive_loss.zig");
const multitask_loss = @import("multitask_loss.zig");
const regularization = @import("regularization.zig");
const optimizer = @import("optimizer.zig");
const curriculum = @import("curriculum.zig");

pub const TrainingStepMetrics = struct {
    global_step: u64,
    curriculum_stage: u8,
    joint_loss: f32,
    contrastive_loss: f32,
    learned_temperature: f32,
    grad_norm: f32,
    effective_dim_permille: u16,
    stage_advanced: bool,
};

pub const TrainingRuntime = struct {
    allocator: std.mem.Allocator,
    scaler: temperature_scaling.TemperatureScaler,
    opt: optimizer.AdamWOptimizer,
    curr: curriculum.CurriculumController,
    weights: []f32,
    grads: []f32,

    pub fn init(
        allocator: std.mem.Allocator,
        detected_b300_gpus: u32,
        global_batch_size: u32,
    ) !TrainingRuntime {
        const param_count: usize = 4096;
        const weights = try allocator.alloc(f32, param_count);
        errdefer allocator.free(weights);
        const grads = try allocator.alloc(f32, param_count);
        errdefer allocator.free(grads);

        for (weights, 0..) |*w, i| {
            w.* = @sin(@as(f32, @floatFromInt(i + 1)) * 0.01) * 0.05;
        }
        @memset(grads, 0.0);

        return .{
            .allocator = allocator,
            .scaler = temperature_scaling.TemperatureScaler.init(0.07, 0.015, 0.50),
            .opt = try optimizer.AdamWOptimizer.init(allocator, param_count, 0.01, 1.0),
            .curr = curriculum.CurriculumController.init(detected_b300_gpus, global_batch_size),
            .weights = weights,
            .grads = grads,
        };
    }

    pub fn deinit(self: *TrainingRuntime) void {
        self.opt.deinit();
        self.allocator.free(self.weights);
        self.allocator.free(self.grads);
    }

    pub fn executeStep(
        self: *TrainingRuntime,
        pos_sim: f32,
        neg_sims: []const f32,
        batch_embeddings: []const [256]f32,
    ) TrainingStepMetrics {
        const c_res = contrastive_loss.computeInfoNceLoss(
            pos_sim,
            neg_sims,
            null,
            self.scaler,
            .info_nce,
        );
        const reg = regularization.computeAntiCollapseRegularization(batch_embeddings, 0.06);
        const mt = multitask_loss.computeJointMultiTaskLoss(.{
            .contrastive_loss = c_res.loss_value,
            .canonical_url_loss = 0.08,
            .entity_classification_loss = 0.11,
            .passage_extraction_loss = 0.14,
            .paragraph_prediction_loss = 0.09,
            .link_prediction_loss = 0.12,
            .ranking_distillation_loss = 0.07,
        }, .{});

        const total_loss = mt.total_joint_loss + reg.variance_penalty * 0.05 + reg.covariance_penalty * 0.025;
        const spec = self.curr.currentSpec();

        for (self.grads, 0..) |*g, i| {
            const factor: f32 = @cos(@as(f32, @floatFromInt(i + 1)) * 0.03);
            g.* = c_res.grad_wrt_positive_logit * factor * 0.01 + self.weights[i] * 0.001;
        }

        const grad_norm = self.opt.step(self.weights, self.grads, spec.base_lr);
        const updated_temp = self.scaler.updateTemperature(c_res.grad_wrt_temperature, spec.base_lr * 0.1);
        const advanced = self.curr.advanceStepAndCheckTransition(880);

        return .{
            .global_step = self.curr.global_step,
            .curriculum_stage = @intFromEnum(self.curr.current_stage),
            .joint_loss = total_loss,
            .contrastive_loss = c_res.loss_value,
            .learned_temperature = updated_temp,
            .grad_norm = grad_norm,
            .effective_dim_permille = reg.effective_dimensionality_ratio_permille,
            .stage_advanced = advanced,
        };
    }
};
