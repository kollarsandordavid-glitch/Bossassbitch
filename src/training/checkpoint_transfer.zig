const std = @import("std");
const checkpoint = @import("../models/checkpoint.zig");
const model_version = @import("../models/model_version.zig");
const model_artifacts = @import("modal_artifacts");

pub const CheckpointTransferClient = struct {
    allocator: std.mem.Allocator,
    ckpt_mgr: *checkpoint.CheckpointManager,
    transferred_count: std.atomic.Value(u64),
    transferred_bytes: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, ckpt_mgr: *checkpoint.CheckpointManager) CheckpointTransferClient {
        return .{
            .allocator = allocator,
            .ckpt_mgr = ckpt_mgr,
            .transferred_count = std.atomic.Value(u64).init(0),
            .transferred_bytes = std.atomic.Value(u64).init(0),
        };
    }

    pub fn persistAndPublishCheckpoint(
        self: *CheckpointTransferClient,
        descriptor: model_version.ModelVersionDescriptor,
        stage: u8,
        global_step: u64,
        weights: []const f32,
        optimizer_state: []const f32,
    ) !model_artifacts.ArtifactDescriptor {
        try descriptor.validateInvariants();
        const artifact = try self.ckpt_mgr.saveModelCheckpoint(
            descriptor,
            stage,
            global_step,
            weights,
            optimizer_state,
        );
        _ = self.transferred_count.fetchAdd(1, .monotonic);
        const total_bytes: u64 = @intCast((weights.len + optimizer_state.len) * @sizeOf(f32));
        _ = self.transferred_bytes.fetchAdd(total_bytes, .monotonic);
        return artifact;
    }

    pub fn verifyPublishedCheckpoint(self: *CheckpointTransferClient, file_name: []const u8) !model_version.ModelVersionDescriptor {
        return self.ckpt_mgr.validateCheckpointFile(file_name);
    }
};
