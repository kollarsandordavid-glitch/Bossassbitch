const std = @import("std");
const candidate_scanner = @import("../scoring/candidate_scanner.zig");
const checksums = @import("../util/checksums.zig");

pub const SEGMENT_MAGIC: u32 = 0x56534547;
pub const SEGMENT_VERSION: u32 = 1;

pub const SegmentFileHeader = extern struct {
    magic: u32 align(1),
    version: u32 align(1),
    shard_id: u32 align(1),
    generation_id: u64 align(1),
    record_count: u64 align(1),
    payload_crc32: u32 align(1),
    reserved: [32]u8 align(1),
};

comptime {
    if (@sizeOf(SegmentFileHeader) != 64) {
        @compileError("SegmentFileHeader must be 64 bytes for cache-line alignment");
    }
}

pub const MmapSegmentStore = struct {
    allocator: std.mem.Allocator,
    base_dir: []u8,

    pub fn init(allocator: std.mem.Allocator, base_dir: []const u8) !MmapSegmentStore {
        try std.fs.cwd().makePath(base_dir);
        return .{
            .allocator = allocator,
            .base_dir = try allocator.dupe(u8, base_dir),
        };
    }

    pub fn deinit(self: *MmapSegmentStore) void {
        self.allocator.free(self.base_dir);
    }

    pub fn writeImmutableSegment(
        self: *MmapSegmentStore,
        shard_id: u32,
        generation_id: u64,
        records: []const candidate_scanner.AlignedCandidateScanRecord,
    ) !u32 {
        const rec_bytes = std.mem.sliceAsBytes(records);
        const crc = checksums.crc32(rec_bytes);

        const hdr = SegmentFileHeader{
            .magic = std.mem.nativeToLittle(u32, SEGMENT_MAGIC),
            .version = std.mem.nativeToLittle(u32, SEGMENT_VERSION),
            .shard_id = std.mem.nativeToLittle(u32, shard_id),
            .generation_id = std.mem.nativeToLittle(u64, generation_id),
            .record_count = std.mem.nativeToLittle(u64, @intCast(records.len)),
            .payload_crc32 = std.mem.nativeToLittle(u32, crc),
            .reserved = [_]u8{0} ** 32,
        };

        var tmp_buf: [512]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}/shard_{d}_gen_{d}.seg.tmp", .{
            self.base_dir,
            shard_id,
            generation_id,
        });
        var final_buf: [512]u8 = undefined;
        const final_path = try std.fmt.bufPrint(&final_buf, "{s}/shard_{d}_gen_{d}.seg", .{
            self.base_dir,
            shard_id,
            generation_id,
        });

        {
            var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(std.mem.asBytes(&hdr));
            try file.writeAll(rec_bytes);
            try file.sync();
        }
        try std.fs.cwd().rename(tmp_path, final_path);
        return crc;
    }

    pub fn loadSegmentRecords(
        self: *MmapSegmentStore,
        shard_id: u32,
        generation_id: u64,
    ) ![]candidate_scanner.AlignedCandidateScanRecord {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/shard_{d}_gen_{d}.seg", .{
            self.base_dir,
            shard_id,
            generation_id,
        });

        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var raw_hdr: SegmentFileHeader = undefined;
        const h_read = try file.readAll(std.mem.asBytes(&raw_hdr));
        if (h_read != @sizeOf(SegmentFileHeader)) return error.CorruptedSegment;

        if (std.mem.littleToNative(u32, raw_hdr.magic) != SEGMENT_MAGIC or
            std.mem.littleToNative(u32, raw_hdr.version) != SEGMENT_VERSION)
        {
            return error.CorruptedSegment;
        }

        const count: usize = @intCast(std.mem.littleToNative(u64, raw_hdr.record_count));
        const expected_crc = std.mem.littleToNative(u32, raw_hdr.payload_crc32);

        const records = try self.allocator.alloc(candidate_scanner.AlignedCandidateScanRecord, count);
        errdefer self.allocator.free(records);

        const rec_bytes = std.mem.sliceAsBytes(records);
        const r_read = try file.readAll(rec_bytes);
        if (r_read != rec_bytes.len) return error.CorruptedSegment;
        if (!checksums.verifyCrc32(rec_bytes, expected_crc)) return error.ChecksumMismatch;

        return records;
    }
};
