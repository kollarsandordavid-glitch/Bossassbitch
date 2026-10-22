const std = @import("std");
const checkpoint = @import("../models/checkpoint.zig");
const model_version = @import("../models/model_version.zig");
const model_artifacts = @import("modal_artifacts");

pub const CheckpointStore = struct {
    allocator: std.mem.Allocator,
    manager: checkpoint.CheckpointManager,
    committed_checkpoints: std.atomic.Value(u64),
    latest_model_version: std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator, checkpoint_dir: []const u8) !CheckpointStore {
        return .{
            .allocator = allocator,
            .manager = try checkpoint.CheckpointManager.init(allocator, checkpoint_dir),
            .committed_checkpoints = std.atomic.Value(u64).init(0),
            .latest_model_version = std.atomic.Value(u32).init(1001),
        };
    }

    pub fn deinit(self: *CheckpointStore) void {
        self.manager.deinit();
    }

    pub fn commitCheckpoint(
        self: *CheckpointStore,
        descriptor: model_version.ModelVersionDescriptor,
        stage: u8,
        global_step: u64,
        weights: []const f32,
        optimizer_state: []const f32,
    ) !model_artifacts.ArtifactDescriptor {
        const artifact = try self.manager.saveModelCheckpoint(
            descriptor,
            stage,
            global_step,
            weights,
            optimizer_state,
        );
        _ = self.committed_checkpoints.fetchAdd(1, .monotonic);
        self.latest_model_version.store(descriptor.model_version, .release);
        return artifact;
    }

    pub fn verifyCheckpoint(self: *CheckpointStore, file_name: []const u8) !model_version.ModelVersionDescriptor {
        return self.manager.validateCheckpointFile(file_name);
    }
};
