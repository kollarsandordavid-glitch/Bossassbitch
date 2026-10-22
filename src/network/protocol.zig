const std = @import("std");

pub const RPC_MAGIC: u32 = 0x4E535250;
pub const RPC_VERSION: u16 = 1;

pub const RpcMessageType = enum(u16) {
    shard_query_request = 1,
    shard_query_response = 2,
    replication_append_request = 3,
    replication_append_response = 4,
    heartbeat_ping = 5,
    heartbeat_pong = 6,
    shard_transfer_chunk = 7,
    shard_transfer_ack = 8,
};

pub const RpcFrameHeader = extern struct {
    magic: u32 align(1),
    version: u16 align(1),
    msg_type: u16 align(1),
    request_id: u64 align(1),
    deadline_ms: u64 align(1),
    generation_id: u64 align(1),
    payload_len: u32 align(1),
    crc32: u32 align(1),
};

pub const ShardCandidateRecord = extern struct {
    doc_id: u64 align(1),
    centroid_id: u32 align(1),
    shard_id: u16 align(1),
    flags: u16 align(1),
    binary_score: f32 align(1),
    norm_compensated_score: f32 align(1),
    freshness_ms: u64 align(1),
    quality_permille: u16 align(1),
    reserved: u16 align(1),
};

pub const ShardQueryWireHeader = extern struct {
    index_generation: u64 align(1),
    model_version: u32 align(1),
    top_k: u32 align(1),
    nprobe: u32 align(1),
    min_quality_permille: u16 align(1),
    filter_flags: u16 align(1),
    min_published_ms: u64 align(1),
    max_published_ms: u64 align(1),
    query_norm: f32 align(1),
    probed_centroid_count: u32 align(1),
    packed_query_binary: [32]u8 align(1),
    retained_query_vector: [256]f32 align(1),
};
