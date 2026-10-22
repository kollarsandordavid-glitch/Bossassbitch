const std = @import("std");
const numeric_stability = @import("../scoring/numeric_stability.zig");

pub const AdamWOptimizer = struct {
    allocator: std.mem.Allocator,
    param_count: usize,
    m: []f32,
    v: []f32,
    beta1: f32,
    beta2: f32,
    eps: f32,
    weight_decay: f32,
    max_grad_norm: f32,
    step_count: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        param_count: usize,
        weight_decay: f32,
        max_grad_norm: f32,
    ) !AdamWOptimizer {
        const m = try allocator.alloc(f32, param_count);
        errdefer allocator.free(m);
        const v = try allocator.alloc(f32, param_count);
        errdefer allocator.free(v);
        @memset(m, 0.0);
        @memset(v, 0.0);

        return .{
            .allocator = allocator,
            .param_count = param_count,
            .m = m,
            .v = v,
            .beta1 = 0.9,
            .beta2 = 0.999,
            .eps = 1e-8,
            .weight_decay = weight_decay,
            .max_grad_norm = max_grad_norm,
            .step_count = 0,
        };
    }

    pub fn deinit(self: *AdamWOptimizer) void {
        self.allocator.free(self.m);
        self.allocator.free(self.v);
    }

    pub fn step(self: *AdamWOptimizer, params: []f32, grads: []f32, learning_rate: f32) f32 {
        const len = @min(self.param_count, @min(params.len, grads.len));
        const grad_norm = numeric_stability.safeL2Norm(grads[0..len]);
        const clip_scale: f32 = if (grad_norm > self.max_grad_norm and grad_norm > 1e-9)
            self.max_grad_norm / grad_norm
        else
            1.0;

        self.step_count += 1;
        const t_f: f32 = @floatFromInt(self.step_count);
        const bias_corr1 = 1.0 - std.math.pow(f32, self.beta1, t_f);
        const bias_corr2 = 1.0 - std.math.pow(f32, self.beta2, t_f);

        for (0..len) |i| {
            const g = if (std.math.isFinite(grads[i])) grads[i] * clip_scale else 0.0;
            self.m[i] = self.beta1 * self.m[i] + (1.0 - self.beta1) * g;
            self.v[i] = self.beta2 * self.v[i] + (1.0 - self.beta2) * (g * g);

            const m_hat = self.m[i] / @max(1e-8, bias_corr1);
            const v_hat = self.v[i] / @max(1e-8, bias_corr2);

            params[i] -= learning_rate * (self.weight_decay * params[i] + m_hat / (@sqrt(v_hat) + self.eps));
        }

        return grad_norm;
    }
};
