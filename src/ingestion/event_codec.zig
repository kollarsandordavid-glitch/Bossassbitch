const std = @import("std");
const binary_codec = @import("../util/binary_codec.zig");

pub const EVENT_MAGIC: u32 = 0x494E4745;
pub const EVENT_SCHEMA_VERSION: u16 = 1;

pub const IngestionEvent = struct {
    sequence_id: u64,
    idempotency_key: u64,
    doc_id: u64,
    domain_id: u64,
    canonical_url: []u8,
    title: []u8,
    body_text: []u8,
    language: []u8,
    published_at_ms: u64,
    quality_score_permille: u16,
    spam_probability_permille: u16,
    priority_flag: bool,

    pub fn deinit(self: *IngestionEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_url);
        allocator.free(self.title);
        allocator.free(self.body_text);
        allocator.free(self.language);
    }
};

pub fn encodeEvent(allocator: std.mem.Allocator, ev: IngestionEvent) ![]u8 {
    var writer = binary_codec.BinaryWriter.init(allocator);
    defer writer.deinit();

    try writer.writeU32(EVENT_MAGIC);
    try writer.writeU16(EVENT_SCHEMA_VERSION);
    try writer.writeU64(ev.sequence_id);
    try writer.writeU64(ev.idempotency_key);
    try writer.writeU64(ev.doc_id);
    try writer.writeU64(ev.domain_id);
    try writer.writeBytes(ev.canonical_url);
    try writer.writeBytes(ev.title);
    try writer.writeBytes(ev.body_text);
    try writer.writeBytes(ev.language);
    try writer.writeU64(ev.published_at_ms);
    try writer.writeU16(ev.quality_score_permille);
    try writer.writeU16(ev.spam_probability_permille);
    try writer.writeU8(if (ev.priority_flag) 1 else 0);

    return writer.finalizeWithCrc();
}

pub fn decodeEvent(allocator: std.mem.Allocator, bytes: []const u8) !IngestionEvent {
    var reader = try binary_codec.BinaryReader.verifyTrailingCrc(bytes);
    const magic = try reader.readU32();
    if (magic != EVENT_MAGIC) return error.InvalidMagic;
    const ver = try reader.readU16();
    if (ver != EVENT_SCHEMA_VERSION) return error.UnsupportedVersion;

    const seq = try reader.readU64();
    const idem = try reader.readU64();
    const doc_id = try reader.readU64();
    const dom_id = try reader.readU64();
    const curl = try reader.readBytes();
    const title = try reader.readBytes();
    const body = try reader.readBytes();
    const lang = try reader.readBytes();
    const pub_ms = try reader.readU64();
    const qual = try reader.readU16();
    const spam = try reader.readU16();
    const prio = (try reader.readU8()) != 0;

    return .{
        .sequence_id = seq,
        .idempotency_key = idem,
        .doc_id = doc_id,
        .domain_id = dom_id,
        .canonical_url = try allocator.dupe(u8, curl),
        .title = try allocator.dupe(u8, title),
        .body_text = try allocator.dupe(u8, body),
        .language = try allocator.dupe(u8, lang),
        .published_at_ms = pub_ms,
        .quality_score_permille = qual,
        .spam_probability_permille = spam,
        .priority_flag = prio,
    };
}
