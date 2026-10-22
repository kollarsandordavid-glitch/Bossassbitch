const std = @import("std");

pub const TemperatureScaler = struct {
    log_temperature: f32,
    min_temperature: f32,
    max_temperature: f32,
    grad_accum: f32,
    updates_count: u64,

    pub fn init(initial_temp: f32, min_temp: f32, max_temp: f32) TemperatureScaler {
        const clamped = std.math.clamp(initial_temp, min_temp, max_temp);
        return .{
            .log_temperature = @log(clamped),
            .min_temperature = min_temp,
            .max_temperature = max_temp,
            .grad_accum = 0.0,
            .updates_count = 0,
        };
    }

    pub fn currentTemperature(self: TemperatureScaler) f32 {
        const raw = @exp(self.log_temperature);
        return std.math.clamp(raw, self.min_temperature, self.max_temperature);
    }

    pub fn inverseTemperature(self: TemperatureScaler) f32 {
        return 1.0 / self.currentTemperature();
    }

    pub fn scaleSimilarity(self: TemperatureScaler, cosine_sim: f32) f32 {
        const temp = self.currentTemperature();
        return cosine_sim / temp;
    }

    pub fn updateTemperature(self: *TemperatureScaler, grad_wrt_temp: f32, learning_rate: f32) f32 {
        if (!std.math.isFinite(grad_wrt_temp)) return self.currentTemperature();
        self.grad_accum = self.grad_accum * 0.9 + grad_wrt_temp * 0.1;
        self.log_temperature -= learning_rate * std.math.clamp(grad_wrt_temp, -1.0, 1.0);
        const clamped_temp = std.math.clamp(@exp(self.log_temperature), self.min_temperature, self.max_temperature);
        self.log_temperature = @log(clamped_temp);
        self.updates_count += 1;
        return clamped_temp;
    }
};
