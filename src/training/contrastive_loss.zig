const std = @import("std");
const temperature_scaling = @import("temperature_scaling.zig");
const numeric_stability = @import("../scoring/numeric_stability.zig");

pub const ContrastiveObjectiveMode = enum {
    info_nce,
    decoupled_contrastive,
    margin_mse,
};

pub const ContrastiveLossResult = struct {
    loss_value: f32,
    positive_probability: f32,
    grad_wrt_positive_logit: f32,
    grad_wrt_temperature: f32,
    is_finite: bool,
};

pub fn computeInfoNceLoss(
    positive_similarity: f32,
    negative_similarities: []const f32,
    negative_weights: ?[]const f32,
    scaler: temperature_scaling.TemperatureScaler,
    mode: ContrastiveObjectiveMode,
) ContrastiveLossResult {
    const temp = scaler.currentTemperature();
    const pos_logit = positive_similarity / temp;

    var max_logit: f32 = pos_logit;
    for (negative_similarities) |neg_sim| {
        const l = neg_sim / temp;
        if (l > max_logit) max_logit = l;
    }

    var neg_sum_exp = numeric_stability.NeumaierAccumulator{};
    var weighted_neg_logit_sum = numeric_stability.NeumaierAccumulator{};

    for (negative_similarities, 0..) |neg_sim, idx| {
        const w: f32 = if (negative_weights) |nw|
            if (idx < nw.len) nw[idx] else 1.0
        else
            1.0;
        const neg_logit = neg_sim / temp;
        const exp_val = w * @exp(neg_logit - max_logit);
        neg_sum_exp.add(exp_val);
        weighted_neg_logit_sum.add(exp_val * neg_logit);
    }

    const pos_exp = if (mode == .decoupled_contrastive) 0.0 else @exp(pos_logit - max_logit);
    const total_exp = @max(1e-12, pos_exp + neg_sum_exp.resultF32());
    const log_sum_exp = max_logit + @log(total_exp);

    const loss = switch (mode) {
        .info_nce, .decoupled_contrastive => log_sum_exp - pos_logit,
        .margin_mse => blk: {
            const best_neg = if (negative_similarities.len > 0) negative_similarities[0] else 0.0;
            const margin_diff = (positive_similarity - best_neg) - 0.25;
            break :blk margin_diff * margin_diff;
        },
    };

    const pos_prob = std.math.clamp(@exp(pos_logit - log_sum_exp), 0.0, 1.0);
    const grad_pos = pos_prob - 1.0;
    const expected_neg_logit = weighted_neg_logit_sum.resultF32() / total_exp;
    const grad_temp = (pos_logit - expected_neg_logit) / @max(1e-4, temp);

    const finite = std.math.isFinite(loss) and std.math.isFinite(grad_pos) and std.math.isFinite(grad_temp);
    return .{
        .loss_value = if (finite) loss else 0.0,
        .positive_probability = if (finite) pos_prob else 0.0,
        .grad_wrt_positive_logit = if (finite) grad_pos else 0.0,
        .grad_wrt_temperature = if (finite) grad_temp else 0.0,
        .is_finite = finite,
    };
}
