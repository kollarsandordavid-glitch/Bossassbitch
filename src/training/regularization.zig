const std = @import("std");

pub const RegularizationReport = struct {
    variance_penalty: f32,
    covariance_penalty: f32,
    effective_dimensionality_ratio_permille: u16,
    collapse_detected: bool,
};

pub fn computeAntiCollapseRegularization(
    batch_embeddings: []const [256]f32,
    target_std: f32,
) RegularizationReport {
    if (batch_embeddings.len < 2) {
        return .{
            .variance_penalty = 0.0,
            .covariance_penalty = 0.0,
            .effective_dimensionality_ratio_permille = 1000,
            .collapse_detected = false,
        };
    }

    const n_f: f32 = @floatFromInt(batch_embeddings.len);
    var means: [256]f32 = [_]f32{0.0} ** 256;
    for (batch_embeddings) |emb| {
        for (0..256) |d| {
            means[d] += emb[d];
        }
    }
    for (0..256) |d| {
        means[d] /= n_f;
    }

    var var_penalty_sum: f32 = 0.0;
    var active_dims: u32 = 0;
    var variances: [256]f32 = [_]f32{0.0} ** 256;

    for (0..256) |d| {
        var sq: f32 = 0.0;
        for (batch_embeddings) |emb| {
            const diff = emb[d] - means[d];
            sq += diff * diff;
        }
        const variance = sq / (n_f - 1.0);
        variances[d] = variance;
        const std_dev = @sqrt(variance + 1e-4);
        if (std_dev > 0.01) active_dims += 1;
        var_penalty_sum += @max(0.0, target_std - std_dev);
    }

    var cov_penalty_sum: f32 = 0.0;
    for (0..256) |i| {
        for (i + 1..256) |j| {
            var cov: f32 = 0.0;
            for (batch_embeddings) |emb| {
                cov += (emb[i] - means[i]) * (emb[j] - means[j]);
            }
            cov /= n_f;
            cov_penalty_sum += cov * cov;
        }
    }

    const eff_ratio: u16 = @intCast((active_dims * 1000) / 256);
    return .{
        .variance_penalty = var_penalty_sum / 256.0,
        .covariance_penalty = cov_penalty_sum / 256.0,
        .effective_dimensionality_ratio_permille = eff_ratio,
        .collapse_detected = eff_ratio < 250,
    };
}

pub fn applyCslsHubnessMitigation(
    raw_similarity: f32,
    query_knn_mean_sim: f32,
    doc_knn_mean_sim: f32,
    citation_hub_degree: u32,
) f32 {
    const csls = 2.0 * raw_similarity - 0.5 * (query_knn_mean_sim + doc_knn_mean_sim);
    if (citation_hub_degree <= 100) return csls;
    const hub_damp = @log(@as(f32, @floatFromInt(citation_hub_degree))) * 0.015;
    if (raw_similarity >= 0.82) {
        return csls - @min(0.03, hub_damp * 0.25);
    }
    return csls - @min(0.12, hub_damp);
}
