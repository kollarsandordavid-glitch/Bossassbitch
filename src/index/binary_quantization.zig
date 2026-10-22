const std = @import("std");
const binary_scoring = @import("../scoring/binary_scoring.zig");

pub const BinaryQuantizer = struct {
    quantization_version: u16,
    enable_dithering: bool,
    dither_seed: u64,
    dither_amplitude: f32,
    zero_threshold: f32,

    pub fn init(enable_dithering: bool, dither_seed: u64, dither_amplitude_milli: u32) BinaryQuantizer {
        return .{
            .quantization_version = binary_scoring.QUANTIZATION_VERSION,
            .enable_dithering = enable_dithering,
            .dither_seed = dither_seed,
            .dither_amplitude = @as(f32, @floatFromInt(dither_amplitude_milli)) / 1000.0,
            .zero_threshold = 0.0,
        };
    }

    pub fn encodeVector256(self: BinaryQuantizer, retained: *const [256]f32) binary_scoring.QuantizedBinaryVector {
        return binary_scoring.quantizeRetained256(retained, .{
            .zero_threshold = self.zero_threshold,
            .enable_stochastic_dithering = self.enable_dithering,
            .dither_seed = self.dither_seed,
            .dither_amplitude = self.dither_amplitude,
        });
    }

    pub fn encodeBatch256(
        self: BinaryQuantizer,
        inputs: []const [256]f32,
        outputs: []binary_scoring.QuantizedBinaryVector,
    ) usize {
        const count = @min(inputs.len, outputs.len);
        for (0..count) |i| {
            outputs[i] = self.encodeVector256(&inputs[i]);
        }
        return count;
    }
};
