const std = @import("std");
const numeric_stability = @import("numeric_stability.zig");

pub const SUBVECTOR_COUNT: usize = 32;
pub const SUBVECTOR_BITS: usize = 8;
pub const LUT_ENTRIES_PER_SUBVECTOR: usize = 256;
pub const NIBBLE_SUBVECTOR_COUNT: usize = 64;
pub const NIBBLE_LUT_ENTRIES: usize = 16;

pub const QueryLookupTables = struct {
    byte_tables: [SUBVECTOR_COUNT][LUT_ENTRIES_PER_SUBVECTOR]f32 align(64),
    nibble_tables_q8: [NIBBLE_SUBVECTOR_COUNT][NIBBLE_LUT_ENTRIES]i8 align(64),
    nibble_scale: f32,
    query_l2_norm: f32,
    packed_query_signs: [SUBVECTOR_COUNT]u8,

    pub fn build(query_retained_256: *const [256]f32) QueryLookupTables {
        var normalized: [256]f32 = query_retained_256.*;
        const q_norm = numeric_stability.normalizeInPlace(&normalized);

        var out: QueryLookupTables = undefined;
        out.query_l2_norm = q_norm;

        var max_abs_nibble_sum: f32 = 1e-6;
        for (0..NIBBLE_SUBVECTOR_COUNT) |nib_idx| {
            var local_abs: f32 = 0.0;
            for (0..4) |b| {
                local_abs += @abs(normalized[nib_idx * 4 + b]);
            }
            if (local_abs > max_abs_nibble_sum) max_abs_nibble_sum = local_abs;
        }
        out.nibble_scale = max_abs_nibble_sum / 120.0;
        const inv_nibble_scale = 1.0 / out.nibble_scale;

        for (0..SUBVECTOR_COUNT) |sub_idx| {
            const base_dim = sub_idx * 8;
            var q_byte: u8 = 0;
            for (0..8) |b| {
                if (normalized[base_dim + b] >= 0.0) {
                    q_byte |= (@as(u8, 1) << @intCast(b));
                }
            }
            out.packed_query_signs[sub_idx] = q_byte;

            for (0..LUT_ENTRIES_PER_SUBVECTOR) |pattern| {
                var acc: f32 = 0.0;
                for (0..8) |bit| {
                    const sign: f32 = if (((pattern >> @intCast(bit)) & 1) == 1) 1.0 else -1.0;
                    acc += sign * normalized[base_dim + bit];
                }
                out.byte_tables[sub_idx][pattern] = acc;
            }
        }

        for (0..NIBBLE_SUBVECTOR_COUNT) |nib_idx| {
            const base_dim = nib_idx * 4;
            for (0..NIBBLE_LUT_ENTRIES) |pattern| {
                var acc: f32 = 0.0;
                for (0..4) |bit| {
                    const sign: f32 = if (((pattern >> @intCast(bit)) & 1) == 1) 1.0 else -1.0;
                    acc += sign * normalized[base_dim + bit];
                }
                const scaled = std.math.clamp(@round(acc * inv_nibble_scale), -127.0, 127.0);
                out.nibble_tables_q8[nib_idx][pattern] = @intFromFloat(scaled);
            }
        }

        return out;
    }
};
