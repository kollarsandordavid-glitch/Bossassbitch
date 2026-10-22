const std = @import("std");

pub const VisibilityBoundary = struct {
    generation_id: u64,
    commit_sequence: u64,
    model_version: u32,
    quantization_version: u16,
};

pub const ConsistencyCoordinator = struct {
    active_generation: std.atomic.Value(u64),
    commit_sequence: std.atomic.Value(u64),
    active_model_version: std.atomic.Value(u32),
    write_quorum: u32,
    read_quorum: u32,

    pub fn init(initial_generation: u64, initial_model_version: u32, write_quorum: u32, read_quorum: u32) ConsistencyCoordinator {
        return .{
            .active_generation = std.atomic.Value(u64).init(initial_generation),
            .commit_sequence = std.atomic.Value(u64).init(0),
            .active_model_version = std.atomic.Value(u32).init(initial_model_version),
            .write_quorum = @max(1, write_quorum),
            .read_quorum = @max(1, read_quorum),
        };
    }

    pub fn acquireReadBoundary(self: *const ConsistencyCoordinator) VisibilityBoundary {
        return .{
            .generation_id = self.active_generation.load(.acquire),
            .commit_sequence = self.commit_sequence.load(.acquire),
            .model_version = self.active_model_version.load(.acquire),
            .quantization_version = 1,
        };
    }

    pub fn advanceCommitSequence(self: *ConsistencyCoordinator) u64 {
        return self.commit_sequence.fetchAdd(1, .acq_rel) + 1;
    }

    pub fn publishNewGeneration(self: *ConsistencyCoordinator, model_version: u32) VisibilityBoundary {
        const seq = self.commit_sequence.fetchAdd(1, .acq_rel) + 1;
        self.active_model_version.store(model_version, .release);
        const gen = self.active_generation.fetchAdd(1, .acq_rel) + 1;
        return .{
            .generation_id = gen,
            .commit_sequence = seq,
            .model_version = model_version,
            .quantization_version = 1,
        };
    }
};
