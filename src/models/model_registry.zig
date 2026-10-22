const std = @import("std");
const model_version = @import("model_version.zig");
const checkpoint = @import("checkpoint.zig");
const time_util = @import("../util/time.zig");

pub const RegisteredModelEntry = struct {
    descriptor: model_version.ModelVersionDescriptor,
    curriculum_stage: u8,
    global_step: u64,
    activated_at_ms: u64,
    checkpoint_file: []u8,

    pub fn deinit(self: *RegisteredModelEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.checkpoint_file);
    }
};

pub const ModelRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    active_version: std.atomic.Value(u32),
    active_descriptor: model_version.ModelVersionDescriptor,
    history: std.ArrayList(RegisteredModelEntry),

    pub fn init(allocator: std.mem.Allocator, initial_version: u32) ModelRegistry {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .active_version = std.atomic.Value(u32).init(initial_version),
            .active_descriptor = .{
                .model_version = initial_version,
            },
            .history = std.ArrayList(RegisteredModelEntry).init(allocator),
        };
    }

    pub fn deinit(self: *ModelRegistry) void {
        for (self.history.items) |*item| item.deinit(self.allocator);
        self.history.deinit();
    }

    pub fn currentDescriptor(self: *ModelRegistry) model_version.ModelVersionDescriptor {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.active_descriptor;
    }

    pub fn registerAndActivateCheckpoint(
        self: *ModelRegistry,
        ckpt_mgr: *checkpoint.CheckpointManager,
        checkpoint_file: []const u8,
        curriculum_stage: u8,
        global_step: u64,
    ) !model_version.ModelVersionDescriptor {
        const validated = try ckpt_mgr.validateCheckpointFile(checkpoint_file);
        if (validated.primary_dim != 4096 or validated.retained_dim != 256 or validated.packed_bytes != 32) {
            return error.IncompatibleModelDimension;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.history.append(.{
            .descriptor = validated,
            .curriculum_stage = curriculum_stage,
            .global_step = global_step,
            .activated_at_ms = time_util.nowMillis(),
            .checkpoint_file = try self.allocator.dupe(u8, checkpoint_file),
        });
        self.active_descriptor = validated;
        self.active_version.store(validated.model_version, .release);
        return validated;
    }
};
