const std = @import("std");
const checksums = @import("../util/checksums.zig");
const time_util = @import("../util/time.zig");

pub const SNAPSHOT_MAGIC: u32 = 0x49534E50;

pub const SnapshotManifest = struct {
    generation_id: u64,
    commit_sequence: u64,
    model_version: u32,
    total_documents: u64,
    deleted_documents: u64,
    shard_count: u32,
    created_at_ms: u64,
    manifest_crc32: u32,
};

pub const SnapshotManager = struct {
    allocator: std.mem.Allocator,
    snapshot_dir: []u8,

    pub fn init(allocator: std.mem.Allocator, snapshot_dir: []const u8) !SnapshotManager {
        try std.fs.cwd().makePath(snapshot_dir);
        return .{
            .allocator = allocator,
            .snapshot_dir = try allocator.dupe(u8, snapshot_dir),
        };
    }

    pub fn deinit(self: *SnapshotManager) void {
        self.allocator.free(self.snapshot_dir);
    }

    pub fn createSnapshotManifest(
        self: *SnapshotManager,
        generation_id: u64,
        commit_sequence: u64,
        model_version: u32,
        total_documents: u64,
        deleted_documents: u64,
        shard_count: u32,
    ) !SnapshotManifest {
        const now = time_util.nowMillis();
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try buf.writer().print(
            "{{\"schema_version\":1,\"generation_id\":{d},\"commit_sequence\":{d},\"model_version\":{d},\"total_documents\":{d},\"deleted_documents\":{d},\"shard_count\":{d},\"created_at_ms\":{d}}}",
            .{ generation_id, commit_sequence, model_version, total_documents, deleted_documents, shard_count, now },
        );
        const crc = checksums.crc32(buf.items);

        var tmp_path_buf: [512]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}/snapshot_gen_{d}.json.tmp", .{ self.snapshot_dir, generation_id });
        var final_path_buf: [512]u8 = undefined;
        const final_path = try std.fmt.bufPrint(&final_path_buf, "{s}/snapshot_gen_{d}.json", .{ self.snapshot_dir, generation_id });

        {
            var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(buf.items);
            try file.sync();
        }
        try std.fs.cwd().rename(tmp_path, final_path);

        return .{
            .generation_id = generation_id,
            .commit_sequence = commit_sequence,
            .model_version = model_version,
            .total_documents = total_documents,
            .deleted_documents = deleted_documents,
            .shard_count = shard_count,
            .created_at_ms = now,
            .manifest_crc32 = crc,
        };
    }

    pub fn loadSnapshotHeader(self: *SnapshotManager, generation_id: u64) !SnapshotManifest {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/snapshot_gen_{d}.json", .{ self.snapshot_dir, generation_id });
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(self.allocator, 65536);
        defer self.allocator.free(bytes);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.StorageCorrupted;
        const obj = parsed.value.object;

        const gen = if (obj.get("generation_id")) |v| (if (v == .integer) @as(u64, @intCast(v.integer)) else generation_id) else generation_id;
        const seq = if (obj.get("commit_sequence")) |v| (if (v == .integer) @as(u64, @intCast(v.integer)) else 1) else 1;
        const mver = if (obj.get("model_version")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 1001) else 1001;
        const tdocs = if (obj.get("total_documents")) |v| (if (v == .integer) @as(u64, @intCast(v.integer)) else 0) else 0;
        const ddocs = if (obj.get("deleted_documents")) |v| (if (v == .integer) @as(u64, @intCast(v.integer)) else 0) else 0;
        const scnt = if (obj.get("shard_count")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 32) else 32;
        const cat = if (obj.get("created_at_ms")) |v| (if (v == .integer) @as(u64, @intCast(v.integer)) else 0) else 0;

        return .{
            .generation_id = gen,
            .commit_sequence = seq,
            .model_version = mver,
            .total_documents = tdocs,
            .deleted_documents = ddocs,
            .shard_count = scnt,
            .created_at_ms = cat,
            .manifest_crc32 = checksums.crc32(bytes),
        };
    }
};
