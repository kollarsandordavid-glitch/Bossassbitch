const std = @import("std");
const tensor_ops = @import("../models/tensor_ops.zig");

pub const DriftEvaluationReport = struct {
    mean_perturbation_stability: f32,
    novel_token_ratio_permille: u16,
    lexical_semantic_disagreement_permille: u16,
    drift_score_milli: u32,
    recalibration_triggered: bool,
};

pub const OutOfDistributionDriftDetector = struct {
    allocator: std.mem.Allocator,
    recalibration_threshold_milli: u32,

    pub fn init(allocator: std.mem.Allocator, recalibration_threshold_milli: u32) OutOfDistributionDriftDetector {
        return .{
            .allocator = allocator,
            .recalibration_threshold_milli = recalibration_threshold_milli,
        };
    }

    pub fn generateLexicalPerturbations(
        self: OutOfDistributionDriftDetector,
        base_query: []const u8,
    ) ![3][]u8 {
        const p0 = try std.fmt.allocPrint(self.allocator, "{s} technical architecture specification", .{base_query});
        errdefer self.allocator.free(p0);
        const p1 = try std.fmt.allocPrint(self.allocator, "latest {s} benchmark evaluation", .{base_query});
        errdefer self.allocator.free(p1);
        const p2 = try std.fmt.allocPrint(self.allocator, "{s} primary documentation reference", .{base_query});
        return .{ p0, p1, p2 };
    }

    pub fn evaluateStabilityAndDrift(
        self: OutOfDistributionDriftDetector,
        original_embedding: *const [256]f32,
        perturbed_embeddings: []const [256]f32,
        novel_token_ratio_permille: u16,
        lexical_semantic_disagreement_permille: u16,
    ) DriftEvaluationReport {
        var sim_sum: f32 = 0.0;
        for (perturbed_embeddings) |p_emb| {
            sim_sum += tensor_ops.cosineSimilarity(original_embedding, &p_emb);
        }
        const mean_stab = if (perturbed_embeddings.len > 0)
            sim_sum / @as(f32, @floatFromInt(perturbed_embeddings.len))
        else
            1.0;

        const instability_milli: u32 = @intFromFloat(@max(0.0, (1.0 - mean_stab) * 1000.0));
        const drift_milli: u32 = (instability_milli * 45 +
            @as(u32, novel_token_ratio_permille) * 30 +
            @as(u32, lexical_semantic_disagreement_permille) * 25) / 100;

        return .{
            .mean_perturbation_stability = mean_stab,
            .novel_token_ratio_permille = novel_token_ratio_permille,
            .lexical_semantic_disagreement_permille = lexical_semantic_disagreement_permille,
            .drift_score_milli = drift_milli,
            .recalibration_triggered = drift_milli >= self.recalibration_threshold_milli,
        };
    }
};
