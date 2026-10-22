const std = @import("std");
const event_codec = @import("event_codec.zig");

pub const IngestionWal = struct {
    allocator: std.mem.Allocator,
    partition_id: u32,
    file_path: []u8,
    mutex: std.Thread.Mutex,
    next_sequence_id: u64,
    consumer_offset: u64,
    seen_idempotency_keys: std.AutoHashMap(u64, u64),

    pub fn init(allocator: std.mem.Allocator, wal_dir: []const u8, partition_id: u32) !IngestionWal {
        try std.fs.cwd().makePath(wal_dir);
        var path_buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/stream_part_{d:0>4}.wal", .{ wal_dir, partition_id });
        return .{
            .allocator = allocator,
            .partition_id = partition_id,
            .file_path = try allocator.dupe(u8, p),
            .mutex = .{},
            .next_sequence_id = 1,
            .consumer_offset = 0,
            .seen_idempotency_keys = std.AutoHashMap(u64, u64).init(allocator),
        };
    }

    pub fn deinit(self: *IngestionWal) void {
        self.seen_idempotency_keys.deinit();
        self.allocator.free(self.file_path);
    }

    pub fn appendIdempotent(self: *IngestionWal, event: *event_codec.IngestionEvent) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.seen_idempotency_keys.get(event.idempotency_key)) |existing_seq| {
            event.sequence_id = existing_seq;
            return existing_seq;
        }

        const seq = self.next_sequence_id;
        self.next_sequence_id += 1;
        event.sequence_id = seq;

        const encoded = try event_codec.encodeEvent(self.allocator, event.*);
        defer self.allocator.free(encoded);

        var file = try std.fs.cwd().createFile(self.file_path, .{ .truncate = false, .read = true });
        defer file.close();
        try file.seekFromEnd(0);

        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(encoded.len), .little);
        try file.writeAll(&len_bytes);
        try file.writeAll(encoded);
        try file.sync();

        try self.seen_idempotency_keys.put(event.idempotency_key, seq);
        return seq;
    }

    pub fn replayFromOffset(
        self: *IngestionWal,
        allocator: std.mem.Allocator,
        min_sequence_id: u64,
    ) ![]event_codec.IngestionEvent {
        self.mutex.lock();
        defer self.mutex.unlock();

        var events = std.ArrayList(event_codec.IngestionEvent).init(allocator);
        errdefer {
            for (events.items) |*e| e.deinit(allocator);
            events.deinit();
        }

        var file = std.fs.cwd().openFile(self.file_path, .{}) catch return events.toOwnedSlice();
        defer file.close();

        while (true) {
            var len_bytes: [4]u8 = undefined;
            const n = file.readAll(&len_bytes) catch break;
            if (n < 4) break;
            const rec_len: usize = @intCast(std.mem.readInt(u32, &len_bytes, .little));
            if (rec_len == 0 or rec_len > 32 * 1024 * 1024) break;

            const buf = try allocator.alloc(u8, rec_len);
            defer allocator.free(buf);
            const r = file.readAll(buf) catch break;
            if (r != rec_len) break;

            var decoded = event_codec.decodeEvent(allocator, buf) catch break;
            try self.seen_idempotency_keys.put(decoded.idempotency_key, decoded.sequence_id);
            if (decoded.sequence_id >= self.next_sequence_id) {
                self.next_sequence_id = decoded.sequence_id + 1;
            }
            if (decoded.sequence_id >= min_sequence_id) {
                try events.append(decoded);
            } else {
                decoded.deinit(allocator);
            }
        }
        return events.toOwnedSlice();
    }
};
