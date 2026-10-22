const std = @import("std");

pub const MultiTaskLossWeights = struct {
    contrastive: f32 = 1.0,
    canonical_url: f32 = 0.15,
    entity_classification: f32 = 0.20,
    passage_extraction: f32 = 0.25,
    paragraph_prediction: f32 = 0.20,
    link_prediction: f32 = 0.30,
    ranking_distillation: f32 = 0.15,
};

pub const MultiTaskLossInputs = struct {
    contrastive_loss: f32,
    canonical_url_loss: f32,
    entity_classification_loss: f32,
    passage_extraction_loss: f32,
    paragraph_prediction_loss: f32,
    link_prediction_loss: f32,
    ranking_distillation_loss: f32,
};

pub const MultiTaskLossDiagnostics = struct {
    total_joint_loss: f32,
    task_contributions: [7]f32,
    dominant_task_index: u8,
    dominant_task_share_permille: u16,
    gradient_saturated: bool,
    task_domination_detected: bool,
};

pub fn computeJointMultiTaskLoss(
    inputs: MultiTaskLossInputs,
    weights: MultiTaskLossWeights,
) MultiTaskLossDiagnostics {
    const raw_contribs = [7]f32{
        @max(0.0, inputs.contrastive_loss * weights.contrastive),
        @max(0.0, inputs.canonical_url_loss * weights.canonical_url),
        @max(0.0, inputs.entity_classification_loss * weights.entity_classification),
        @max(0.0, inputs.passage_extraction_loss * weights.passage_extraction),
        @max(0.0, inputs.paragraph_prediction_loss * weights.paragraph_prediction),
        @max(0.0, inputs.link_prediction_loss * weights.link_prediction),
        @max(0.0, inputs.ranking_distillation_loss * weights.ranking_distillation),
    };

    var total: f32 = 0.0;
    var max_val: f32 = 0.0;
    var max_idx: u8 = 0;

    for (raw_contribs, 0..) |c, idx| {
        if (std.math.isFinite(c)) {
            total += c;
            if (c > max_val) {
                max_val = c;
                max_idx = @intCast(idx);
            }
        }
    }

    const share_permille: u16 = if (total <= 1e-8)
        0
    else
        @intFromFloat(std.math.clamp((max_val / total) * 1000.0, 0.0, 1000.0));

    return .{
        .total_joint_loss = total,
        .task_contributions = raw_contribs,
        .dominant_task_index = max_idx,
        .dominant_task_share_permille = share_permille,
        .gradient_saturated = (total < 1e-6 or total > 1e4),
        .task_domination_detected = (share_permille > 850 and max_idx != 0),
    };
}
