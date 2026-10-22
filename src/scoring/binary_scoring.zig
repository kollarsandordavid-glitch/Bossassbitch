const std = @import("std");
const numeric_stability = @import("numeric_stability.zig");

pub const QUANTIZATION_VERSION: u16 = 1;
pub const RETAINED_BITS: usize = 256;
pub const PACKED_BYTES: usize = 32;

pub const QuantizationOptions = struct {
    zero_threshold: f32 = 0.0,
    enable_stochastic_dithering: bool = false,
    dither_seed: u64 = 98765432101234567,
    dither_amplitude: f32 = 0.005,
};

pub const QuantizedBinaryVector = struct {
    quantization_version: u16,
    packed_bytes: [PACKED_BYTES]u8,
    original_l2_norm: f32,
    set_bits_count: u16,
};

pub fn quantizeRetained256(
    retained_coords: *const [RETAINED_BITS]f32,
    opts: QuantizationOptions,
) QuantizedBinaryVector {
    var working: [RETAINED_BITS]f32 = retained_coords.*;
    const orig_norm = numeric_stability.normalizeInPlace(&working);

    var prng = std.Random.DefaultPrng.init(opts.dither_seed);
    const rand = prng.random();

    var packed_out: [PACKED_BYTES]u8 = [_]u8{0} ** PACKED_BYTES;
    var pop_total: u16 = 0;

    for (0..PACKED_BYTES) |byte_idx| {
        var byte_val: u8 = 0;
        for (0..8) |bit_idx| {
            const dim_idx = byte_idx * 8 + bit_idx;
            var coord = working[dim_idx];
            if (opts.enable_stochastic_dithering) {
                const noise = (rand.float(f32) * 2.0 - 1.0) * opts.dither_amplitude;
                coord += noise;
            }
            if (coord >= opts.zero_threshold) {
                byte_val |= (@as(u8, 1) << @intCast(bit_idx));
                pop_total += 1;
            }
        }
        packed_out[byte_idx] = byte_val;
    }

    return .{
        .quantization_version = QUANTIZATION_VERSION,
        .packed_bytes = packed_out,
        .original_l2_norm = orig_norm,
        .set_bits_count = pop_total,
    };
}

pub fn symmetricHammingSimilarity(a: *const [PACKED_BYTES]u8, b: *const [PACKED_BYTES]u8) f32 {
    var xor_pop: u32 = 0;
    for (0..PACKED_BYTES) |i| {
        xor_pop += @popCount(a[i] ^ b[i]);
    }
    const matching_bits: i32 = 256 - @as(i32, @intCast(xor_pop)) * 2;
    return @as(f32, @floatFromInt(matching_bits)) / 256.0;
}
