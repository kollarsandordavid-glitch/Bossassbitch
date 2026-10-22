const std = @import("std");
const binary_codec = @import("../util/binary_codec.zig");

pub const TX_LOG_MAGIC: u32 = 0x54584C47;

pub const TransactionOperation = enum(u8) {
    put_document = 1,
    delete_document = 2,
    put_metadata = 3,
    put_graph_edge = 4,
};

pub const TransactionRecord = struct {
    tx_id: u64,
    op: TransactionOperation,
    entity_id: u64,
    payload: []u8,

    pub fn deinit(self: *TransactionRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};

pub const TransactionLog = struct {
    allocator: std.mem.Allocator,
    log_path: []u8,
    mutex: std.Thread.Mutex,
    next_tx_id: u64,
    sync_on_commit: bool,

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8, sync_on_commit: bool) !TransactionLog {
        try std.fs.cwd().makePath(dir_path);
        var buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "{s}/storage_transactions.log", .{dir_path});
        return .{
            .allocator = allocator,
            .log_path = try allocator.dupe(u8, p),
            .mutex = .{},
            .next_tx_id = 1,
            .sync_on_commit = sync_on_commit,
        };
    }

    pub fn deinit(self: *TransactionLog) void {
        self.allocator.free(self.log_path);
    }

    pub fn appendTransaction(
        self: *TransactionLog,
        op: TransactionOperation,
        entity_id: u64,
        payload: []const u8,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tx_id = self.next_tx_id;
        self.next_tx_id += 1;

        var writer = binary_codec.BinaryWriter.init(self.allocator);
        defer writer.deinit();

        try writer.writeU32(TX_LOG_MAGIC);
        try writer.writeU64(tx_id);
        try writer.writeU8(@intFromEnum(op));
        try writer.writeU64(entity_id);
        try writer.writeBytes(payload);

        const encoded = try writer.finalizeWithCrc();
        defer self.allocator.free(encoded);

        var file = try std.fs.cwd().createFile(self.log_path, .{ .truncate = false, .read = true });
        defer file.close();
        try file.seekFromEnd(0);

        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, @intCast(encoded.len), .little);
        try file.writeAll(&len_bytes);
        try file.writeAll(encoded);
        if (self.sync_on_commit) {
            try file.sync();
        }
        return tx_id;
    }
};
