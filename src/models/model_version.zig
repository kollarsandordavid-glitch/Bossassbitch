const std = @import("std");
const errors = @import("../runtime/errors.zig");

pub const PRIMARY_EMBEDDING_DIM: u32 = 4096;
pub const MATRYOSHKA_RETAINED_DIM: u32 = 256;
pub const PACKED_BINARY_BYTES: u32 = 32;

pub const ModelVersionDescriptor = struct {
    family: []const u8 = "dual-encoder-matryoshka-v1",
    model_version: u32 = 1001,
    quantization_version: u16 = 1,
    primary_dim: u32 = PRIMARY_EMBEDDING_DIM,
    retained_dim: u32 = MATRYOSHKA_RETAINED_DIM,
    packed_bytes: u32 = PACKED_BINARY_BYTES,
    learned_temperature: f32 = 0.07,

    pub fn isCompatibleWith(self: ModelVersionDescriptor, other: ModelVersionDescriptor) bool {
        return self.model_version == other.model_version and
            self.quantization_version == other.quantization_version and
            self.primary_dim == other.primary_dim and
            self.retained_dim == other.retained_dim and
            self.packed_bytes == other.packed_bytes;
    }

    pub fn validateInvariants(self: ModelVersionDescriptor) errors.EngineError!void {
        if (self.primary_dim != PRIMARY_EMBEDDING_DIM or self.retained_dim != MATRYOSHKA_RETAINED_DIM) {
            return error.IncompatibleModelDimension;
        }
        if (self.packed_bytes != PACKED_BINARY_BYTES or self.quantization_version == 0) {
            return error.IncompatibleQuantizationVersion;
        }
        if (!std.math.isFinite(self.learned_temperature) or self.learned_temperature <= 0.0) {
            return error.InvalidConfiguration;
        }
    }

    pub fn canServeLegacyLag(self: ModelVersionDescriptor, candidate_version: u32, max_lag: u32) bool {
        if (candidate_version > self.model_version) return false;
        return (self.model_version - candidate_version) <= max_lag;
    }
};
