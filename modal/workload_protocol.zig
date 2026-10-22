const std = @import("std");

pub const PROTOCOL_MAGIC: u32 = 0x4E534750;
pub const PROTOCOL_VERSION: u32 = 1;
pub const PRIMARY_EMBEDDING_DIM: usize = 4096;
pub const MATRYOSHKA_DIM: usize = 256;
pub const PACKED_BINARY_BYTES: usize = 32;

pub const WorkloadOpCode = enum(u32) {
    embed_batch = 1,
    train_step = 2,
    rerank_batch = 3,
    checkpoint_sync = 4,
    health_probe = 5,
};

pub const GpuProfileKind = enum(u8) {
    nvidia_b300_modal = 1,
    nvidia_h200_reference_144 = 2,
};

pub const HardwareBudget = struct {
    profile: GpuProfileKind,
    detected_gpus: u32,
    reference_gpus: u32,
    per_gpu_memory_bytes: u64,
    effective_micro_batch_size: u32,
    gradient_accumulation_steps: u32,
    global_batch_size: u32,

    pub fn computeForProfile(profile: GpuProfileKind, detected_gpus: u32, target_global_batch: u32) HardwareBudget {
        const safe_gpus: u32 = if (detected_gpus == 0) 1 else detected_gpus;
        const per_gpu_mem: u64 = switch (profile) {
            .nvidia_b300_modal => 288 * 1024 * 1024 * 1024,
            .nvidia_h200_reference_144 => 141 * 1024 * 1024 * 1024,
        };
        const micro_batch: u32 = switch (profile) {
            .nvidia_b300_modal => 64,
            .nvidia_h200_reference_144 => 32,
        };
        const per_step_total = safe_gpus * micro_batch;
        const accum = if (target_global_batch > per_step_total)
            (target_global_batch + per_step_total - 1) / per_step_total
        else
            1;
        return .{
            .profile = profile,
            .detected_gpus = safe_gpus,
            .reference_gpus = 144,
            .per_gpu_memory_bytes = per_gpu_mem,
            .effective_micro_batch_size = micro_batch,
            .gradient_accumulation_steps = accum,
            .global_batch_size = per_step_total * accum,
        };
    }
};

pub const FrameHeader = extern struct {
    magic: u32 align(1),
    version: u32 align(1),
    op_code: u32 align(1),
    payload_len: u32 align(1),
    crc32: u32 align(1),
    model_version: u32 align(1),
    sequence_id: u64 align(1),
};

pub const EmbeddingItemRequest = struct {
    doc_id: u64,
    text: []const u8,
    dom_depth: u16,
    heading_level: u8,
    prominence_permille: u16,
};

pub const EmbeddingItemResponse = struct {
    doc_id: u64,
    model_version: u32,
    primary_vector: [PRIMARY_EMBEDDING_DIM]f32,
    retained_vector: [MATRYOSHKA_DIM]f32,
    packed_binary: [PACKED_BINARY_BYTES]u8,
    original_norm: f32,
};

pub const WorkloadError = error{
    InvalidFrameMagic,
    UnsupportedProtocolVersion,
    PayloadLengthMismatch,
    ChecksumMismatch,
    InvalidOpCode,
    BufferTooSmall,
    OutOfMemory,
};

pub fn encodeFrame(
    allocator: std.mem.Allocator,
    op_code: WorkloadOpCode,
    model_version: u32,
    sequence_id: u64,
    payload: []const u8,
) WorkloadError![]u8 {
    if (payload.len > std.math.maxInt(u32)) return error.BufferTooSmall;
    const header_size = @sizeOf(FrameHeader);
    var out = try allocator.alloc(u8, header_size + payload.len);
    const crc = std.hash.Crc32.hash(payload);
    const hdr = FrameHeader{
        .magic = std.mem.nativeToLittle(u32, PROTOCOL_MAGIC),
        .version = std.mem.nativeToLittle(u32, PROTOCOL_VERSION),
        .op_code = std.mem.nativeToLittle(u32, @intFromEnum(op_code)),
        .payload_len = std.mem.nativeToLittle(u32, @intCast(payload.len)),
        .crc32 = std.mem.nativeToLittle(u32, crc),
        .model_version = std.mem.nativeToLittle(u32, model_version),
        .sequence_id = std.mem.nativeToLittle(u64, sequence_id),
    };
    @memcpy(out[0..header_size], std.mem.asBytes(&hdr));
    if (payload.len > 0) {
        @memcpy(out[header_size..], payload);
    }
    return out;
}

pub const DecodedFrame = struct {
    header: FrameHeader,
    op_code: WorkloadOpCode,
    payload: []const u8,
};

pub fn decodeFrame(bytes: []const u8) WorkloadError!DecodedFrame {
    const header_size = @sizeOf(FrameHeader);
    if (bytes.len < header_size) return error.PayloadLengthMismatch;
    var raw_hdr: FrameHeader = undefined;
    @memcpy(std.mem.asBytes(&raw_hdr), bytes[0..header_size]);
    const hdr = FrameHeader{
        .magic = std.mem.littleToNative(u32, raw_hdr.magic),
        .version = std.mem.littleToNative(u32, raw_hdr.version),
        .op_code = std.mem.littleToNative(u32, raw_hdr.op_code),
        .payload_len = std.mem.littleToNative(u32, raw_hdr.payload_len),
        .crc32 = std.mem.littleToNative(u32, raw_hdr.crc32),
        .model_version = std.mem.littleToNative(u32, raw_hdr.model_version),
        .sequence_id = std.mem.littleToNative(u64, raw_hdr.sequence_id),
    };
    if (hdr.magic != PROTOCOL_MAGIC) return error.InvalidFrameMagic;
    if (hdr.version != PROTOCOL_VERSION) return error.UnsupportedProtocolVersion;
    if (bytes.len < header_size + hdr.payload_len) return error.PayloadLengthMismatch;
    const payload = bytes[header_size .. header_size + hdr.payload_len];
    const computed_crc = std.hash.Crc32.hash(payload);
    if (computed_crc != hdr.crc32) return error.ChecksumMismatch;
    const op = std.meta.intToEnum(WorkloadOpCode, hdr.op_code) catch return error.InvalidOpCode;
    return .{
        .header = hdr,
        .op_code = op,
        .payload = payload,
    };
}
