const std = @import("std");
const checksums = @import("../util/checksums.zig");

pub const NVME_VECTOR_MAGIC: u32 = 0x4E564D45;

pub const NvmePrimaryVectorHeader = extern struct {
    magic: u32 align(1),
    doc_id: u64 align(1),
    model_version: u32 align(1),
    dim: u32 align(1),
    crc32: u32 align(1),
};

pub const NvmePrimaryVectorStore = struct {
    allocator: std.mem.Allocator,
    storage_dir: []u8,
    mutex: std.Thread.Mutex,
    doc_offsets: std.AutoHashMap(u64, u64),
    data_path: []u8,

    pub fn init(allocator: std.mem.Allocator, storage_dir: []const u8) !NvmePrimaryVectorStore {
        try std.fs.cwd().makePath(storage_dir);
        var p_buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&p_buf, "{s}/primary_vectors_4096.nvme", .{storage_dir});
        return .{
            .allocator = allocator,
            .storage_dir = try allocator.dupe(u8, storage_dir),
            .mutex = .{},
            .doc_offsets = std.AutoHashMap(u64, u64).init(allocator),
            .data_path = try allocator.dupe(u8, p),
        };
    }

    pub fn deinit(self: *NvmePrimaryVectorStore) void {
        self.doc_offsets.deinit();
        self.allocator.free(self.data_path);
        self.allocator.free(self.storage_dir);
    }

    pub fn storePrimaryVector4096(
        self: *NvmePrimaryVectorStore,
        doc_id: u64,
        model_version: u32,
        vec: *const [4096]f32,
    ) !void {
        const bytes = std.mem.asBytes(vec);
        const crc = checksums.crc32(bytes);
        const hdr = NvmePrimaryVectorHeader{
            .magic = std.mem.nativeToLittle(u32, NVME_VECTOR_MAGIC),
            .doc_id = std.mem.nativeToLittle(u64, doc_id),
            .model_version = std.mem.nativeToLittle(u32, model_version),
            .dim = std.mem.nativeToLittle(u32, 4096),
            .crc32 = std.mem.nativeToLittle(u32, crc),
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        var file = try std.fs.cwd().createFile(self.data_path, .{ .truncate = false, .read = true });
        defer file.close();
        const offset = try file.getEndPos();
        try file.seekFromEnd(0);
        try file.writeAll(std.mem.asBytes(&hdr));
        try file.writeAll(bytes);

        try self.doc_offsets.put(doc_id, offset);
    }

    pub fn readPrimaryVector4096(
        self: *NvmePrimaryVectorStore,
        doc_id: u64,
        out_vec: *[4096]f32,
    ) !u32 {
        self.mutex.lock();
        const offset = self.doc_offsets.get(doc_id) orelse {
            self.mutex.unlock();
            return error.NotFound;
        };
        self.mutex.unlock();

        var file = try std.fs.cwd().openFile(self.data_path, .{});
        defer file.close();
        try file.seekTo(offset);

        var raw_hdr: NvmePrimaryVectorHeader = undefined;
        const h_read = try file.readAll(std.mem.asBytes(&raw_hdr));
        if (h_read != @sizeOf(NvmePrimaryVectorHeader)) return error.StorageCorrupted;
        if (std.mem.littleToNative(u32, raw_hdr.magic) != NVME_VECTOR_MAGIC) return error.StorageCorrupted;

        const out_bytes = std.mem.asBytes(out_vec);
        const b_read = try file.readAll(out_bytes);
        if (b_read != out_bytes.len) return error.StorageCorrupted;

        const expected_crc = std.mem.littleToNative(u32, raw_hdr.crc32);
        if (!checksums.verifyCrc32(out_bytes, expected_crc)) return error.ChecksumMismatch;
        return std.mem.littleToNative(u32, raw_hdr.model_version);
    }
};
