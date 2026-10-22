const std = @import("std");
const protocol = @import("modal_protocol");

pub const ARTIFACT_MAGIC: u32 = 0x4D444152;
pub const ARTIFACT_VERSION: u32 = 1;

pub const ArtifactDescriptor = struct {
    model_family: []const u8,
    model_version: u32,
    curriculum_stage: u8,
    global_step: u64,
    primary_dim: u32,
    matryoshka_dim: u32,
    learned_temperature: f32,
    weights_crc32: u32,
    optimizer_crc32: u32,
    created_at_ms: u64,
};

pub const PackedArtifactHeader = extern struct {
    magic: u32 align(1),
    version: u32 align(1),
    model_version: u32 align(1),
    curriculum_stage: u8 align(1),
    reserved: [3]u8 align(1),
    global_step: u64 align(1),
    primary_dim: u32 align(1),
    matryoshka_dim: u32 align(1),
    learned_temperature_bits: u32 align(1),
    weights_len: u32 align(1),
    optimizer_len: u32 align(1),
    weights_crc32: u32 align(1),
    optimizer_crc32: u32 align(1),
    created_at_ms: u64 align(1),
};

pub const ArtifactStore = struct {
    allocator: std.mem.Allocator,
    base_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, base_dir: []const u8) !ArtifactStore {
        const owned = try allocator.dupe(u8, base_dir);
        try std.fs.cwd().makePath(owned);
        return .{
            .allocator = allocator,
            .base_dir = owned,
        };
    }

    pub fn deinit(self: *ArtifactStore) void {
        self.allocator.free(self.base_dir);
    }

    pub fn writeCheckpointArtifact(
        self: *ArtifactStore,
        model_version: u32,
        curriculum_stage: u8,
        global_step: u64,
        learned_temperature: f32,
        weights: []const f32,
        optimizer_state: []const f32,
    ) !ArtifactDescriptor {
        const weights_bytes = std.mem.sliceAsBytes(weights);
        const opt_bytes = std.mem.sliceAsBytes(optimizer_state);
        const w_crc = std.hash.Crc32.hash(weights_bytes);
        const o_crc = std.hash.Crc32.hash(opt_bytes);
        const now_ms: u64 = @intCast(@max(0, std.time.milliTimestamp()));

        const hdr = PackedArtifactHeader{
            .magic = std.mem.nativeToLittle(u32, ARTIFACT_MAGIC),
            .version = std.mem.nativeToLittle(u32, ARTIFACT_VERSION),
            .model_version = std.mem.nativeToLittle(u32, model_version),
            .curriculum_stage = curriculum_stage,
            .reserved = .{ 0, 0, 0 },
            .global_step = std.mem.nativeToLittle(u64, global_step),
            .primary_dim = std.mem.nativeToLittle(u32, @intCast(protocol.PRIMARY_EMBEDDING_DIM)),
            .matryoshka_dim = std.mem.nativeToLittle(u32, @intCast(protocol.MATRYOSHKA_DIM)),
            .learned_temperature_bits = std.mem.nativeToLittle(u32, @bitCast(learned_temperature)),
            .weights_len = std.mem.nativeToLittle(u32, @intCast(weights_bytes.len)),
            .optimizer_len = std.mem.nativeToLittle(u32, @intCast(opt_bytes.len)),
            .weights_crc32 = std.mem.nativeToLittle(u32, w_crc),
            .optimizer_crc32 = std.mem.nativeToLittle(u32, o_crc),
            .created_at_ms = std.mem.nativeToLittle(u64, now_ms),
        };

        var path_buf: [512]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&path_buf, "{s}/model_v{d}_step{d}.ckpt.tmp", .{
            self.base_dir,
            model_version,
            global_step,
        });
        var final_buf: [512]u8 = undefined;
        const final_path = try std.fmt.bufPrint(&final_buf, "{s}/model_v{d}_step{d}.ckpt", .{
            self.base_dir,
            model_version,
            global_step,
        });

        {
            var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(std.mem.asBytes(&hdr));
            try file.writeAll(weights_bytes);
            try file.writeAll(opt_bytes);
            try file.sync();
        }
        try std.fs.cwd().rename(tmp_path, final_path);

        return .{
            .model_family = "dual-encoder-matryoshka-v1",
            .model_version = model_version,
            .curriculum_stage = curriculum_stage,
            .global_step = global_step,
            .primary_dim = @intCast(protocol.PRIMARY_EMBEDDING_DIM),
            .matryoshka_dim = @intCast(protocol.MATRYOSHKA_DIM),
            .learned_temperature = learned_temperature,
            .weights_crc32 = w_crc,
            .optimizer_crc32 = o_crc,
            .created_at_ms = now_ms,
        };
    }

    pub fn verifyCheckpointFile(self: *ArtifactStore, file_name: []const u8) !PackedArtifactHeader {
        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.base_dir, file_name });
        var file = try std.fs.cwd().openFile(full_path, .{});
        defer file.close();
        var raw_hdr: PackedArtifactHeader = undefined;
        const read_hdr = try file.readAll(std.mem.asBytes(&raw_hdr));
        if (read_hdr != @sizeOf(PackedArtifactHeader)) return error.CorruptedArtifact;

        const hdr = PackedArtifactHeader{
            .magic = std.mem.littleToNative(u32, raw_hdr.magic),
            .version = std.mem.littleToNative(u32, raw_hdr.version),
            .model_version = std.mem.littleToNative(u32, raw_hdr.model_version),
            .curriculum_stage = raw_hdr.curriculum_stage,
            .reserved = raw_hdr.reserved,
            .global_step = std.mem.littleToNative(u64, raw_hdr.global_step),
            .primary_dim = std.mem.littleToNative(u32, raw_hdr.primary_dim),
            .matryoshka_dim = std.mem.littleToNative(u32, raw_hdr.matryoshka_dim),
            .learned_temperature_bits = std.mem.littleToNative(u32, raw_hdr.learned_temperature_bits),
            .weights_len = std.mem.littleToNative(u32, raw_hdr.weights_len),
            .optimizer_len = std.mem.littleToNative(u32, raw_hdr.optimizer_len),
            .weights_crc32 = std.mem.littleToNative(u32, raw_hdr.weights_crc32),
            .optimizer_crc32 = std.mem.littleToNative(u32, raw_hdr.optimizer_crc32),
            .created_at_ms = std.mem.littleToNative(u64, raw_hdr.created_at_ms),
        };
        if (hdr.magic != ARTIFACT_MAGIC or hdr.version != ARTIFACT_VERSION) return error.CorruptedArtifact;
        if (hdr.primary_dim != protocol.PRIMARY_EMBEDDING_DIM or hdr.matryoshka_dim != protocol.MATRYOSHKA_DIM) {
            return error.IncompatibleDimensions;
        }
        const w_buf = try self.allocator.alloc(u8, hdr.weights_len);
        defer self.allocator.free(w_buf);
        const w_read = try file.readAll(w_buf);
        if (w_read != hdr.weights_len) return error.CorruptedArtifact;
        if (std.hash.Crc32.hash(w_buf) != hdr.weights_crc32) return error.ChecksumMismatch;

        const o_buf = try self.allocator.alloc(u8, hdr.optimizer_len);
        defer self.allocator.free(o_buf);
        const o_read = try file.readAll(o_buf);
        if (o_read != hdr.optimizer_len) return error.CorruptedArtifact;
        if (std.hash.Crc32.hash(o_buf) != hdr.optimizer_crc32) return error.ChecksumMismatch;

        return hdr;
    }
};
