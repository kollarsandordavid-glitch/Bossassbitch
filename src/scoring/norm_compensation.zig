const std = @import("std");

pub const NormCompensationParams = struct {
    reference_norm: f32 = 1.0,
    magnitude_elasticity: f32 = 0.15,
    min_scale: f32 = 0.70,
    max_scale: f32 = 1.30,
};

pub fn computeNormCompensatedScore(
    asymmetric_binary_dot: f32,
    query_norm: f32,
    doc_original_norm: f32,
    doc_quality_permille: u16,
    params: NormCompensationParams,
) f32 {
    const safe_q_norm = if (std.math.isFinite(query_norm) and query_norm > 1e-6) query_norm else 1.0;
    const safe_d_norm = if (std.math.isFinite(doc_original_norm) and doc_original_norm > 1e-6) doc_original_norm else 1.0;

    const inv_sqrt_dim: f32 = 1.0 / 16.0;
    const normalized_asym = (asymmetric_binary_dot * inv_sqrt_dim) / safe_q_norm;

    const log_ratio = @log(safe_d_norm / @max(1e-6, params.reference_norm));
    const damped = std.math.tanh(log_ratio * params.magnitude_elasticity);
    const mag_factor = std.math.clamp(1.0 + damped * 0.25, params.min_scale, params.max_scale);

    const quality_tie_nudge = (@as(f32, @floatFromInt(doc_quality_permille)) - 500.0) * 1e-4;
    return (normalized_asym * mag_factor) + quality_tie_nudge;
}
