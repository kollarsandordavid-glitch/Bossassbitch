const std = @import("std");
const time_util = @import("../util/time.zig");

pub const ReplicaRole = enum(u8) {
    leader = 0,
    follower = 1,
    catching_up = 2,
};

pub const ReplicationLogEntry = struct {
    commit_sequence: u64,
    generation_id: u64,
    shard_id: u32,
    doc_id: u64,
    is_deletion: bool,
    timestamp_ms: u64,
};

pub const ShardReplicationManager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    replication_factor: u32,
    role: ReplicaRole,
    log: std.ArrayList(ReplicationLogEntry),
    replica_applied_seq: [8]u64,

    pub fn init(allocator: std.mem.Allocator, replication_factor: u32) ShardReplicationManager {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .replication_factor = @min(8, @max(1, replication_factor)),
            .role = .leader,
            .log = std.ArrayList(ReplicationLogEntry).init(allocator),
            .replica_applied_seq = [_]u64{0} ** 8,
        };
    }

    pub fn deinit(self: *ShardReplicationManager) void {
        self.log.deinit();
    }

    pub fn appendMutation(
        self: *ShardReplicationManager,
        commit_sequence: u64,
        generation_id: u64,
        shard_id: u32,
        doc_id: u64,
        is_deletion: bool,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.log.append(.{
            .commit_sequence = commit_sequence,
            .generation_id = generation_id,
            .shard_id = shard_id,
            .doc_id = doc_id,
            .is_deletion = is_deletion,
            .timestamp_ms = time_util.nowMillis(),
        });

        for (0..self.replication_factor) |r_idx| {
            self.replica_applied_seq[r_idx] = commit_sequence;
        }
    }

    pub fn maxReplicationLagSeq(self: *ShardReplicationManager) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const leader_seq = self.replica_applied_seq[0];
        var max_lag: u64 = 0;
        for (0..self.replication_factor) |r_idx| {
            const diff = leader_seq -| self.replica_applied_seq[r_idx];
            if (diff > max_lag) max_lag = diff;
        }
        return max_lag;
    }
};
