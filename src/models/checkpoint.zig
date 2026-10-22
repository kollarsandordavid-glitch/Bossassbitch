const std = @import("std");
const model_artifacts = @import("modal_artifacts");
const model_version = @import("model_version.zig");

pub const CheckpointManager = struct {
    allocator: std.mem.Allocator,
    store: model_artifacts.ArtifactStore,

    pub fn init(allocator: std.mem.Allocator, checkpoint_dir: []const u8) !CheckpointManager {
        return .{
            .allocator = allocator,
            .store = try model_artifacts.ArtifactStore.init(allocator, checkpoint_dir),
        };
    }

    pub fn deinit(self: *CheckpointManager) void {
        self.store.deinit();
    }

    pub fn saveModelCheckpoint(
        self: *CheckpointManager,
        descriptor: model_version.ModelVersionDescriptor,
        curriculum_stage: u8,
        global_step: u64,
        weights: []const f32,
        optimizer_state: []const f32,
    ) !model_artifacts.ArtifactDescriptor {
        return self.store.writeCheckpointArtifact(
            descriptor.model_version,
            curriculum_stage,
            global_step,
            descriptor.learned_temperature,
            weights,
            optimizer_state,
        );
    }

    pub fn validateCheckpointFile(self: *CheckpointManager, file_name: []const u8) !model_version.ModelVersionDescriptor {
        const hdr = try self.store.verifyCheckpointFile(file_name);
        return .{
            .family = "dual-encoder-matryoshka-v1",
            .model_version = hdr.model_version,
            .quantization_version = 1,
            .primary_dim = hdr.primary_dim,
            .retained_dim = hdr.matryoshka_dim,
            .packed_bytes = 32,
            .learned_temperature = @bitCast(hdr.learned_temperature_bits),
        };
    }
};
