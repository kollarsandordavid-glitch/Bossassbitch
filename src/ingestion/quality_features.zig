const std = @import("std");
const html_parser = @import("../crawl/html_parser.zig");

pub const QualityFeatureVector = struct {
    text_byte_length: u32,
    unique_token_ratio_permille: u16,
    character_entropy_milli: u32,
    heading_density_permille: u16,
    link_to_text_ratio_permille: u16,
    nofollow_link_ratio_permille: u16,
    perplexity_burstiness_permille: u16,
    structural_coherence_permille: u16,
    source_originality_permille: u16,
};

pub fn extractQualityFeatures(
    title: []const u8,
    body_text: []const u8,
    spans: []const html_parser.StructuralSpan,
    links: []const html_parser.ExtractedLink,
    is_unique_dedup: bool,
) QualityFeatureVector {
    var freq: [256]u32 = [_]u32{0} ** 256;
    for (body_text) |b| {
        freq[b] += 1;
    }

    var entropy: f64 = 0.0;
    if (body_text.len > 0) {
        const total_f: f64 = @floatFromInt(body_text.len);
        for (freq) |count| {
            if (count > 0) {
                const p = @as(f64, @floatFromInt(count)) / total_f;
                entropy -= p * (@log(p) / @log(2.0));
            }
        }
    }

    var token_count: u32 = 0;
    var unique_buckets: [256]bool = [_]bool{false} ** 256;
    var unique_hits: u32 = 0;
    var sentence_lengths: [64]u32 = [_]u32{0} ** 64;
    var sentence_idx: usize = 0;
    var current_sentence_tokens: u32 = 0;

    var tok_iter = std.mem.tokenizeAny(u8, body_text, " \t\r\n");
    while (tok_iter.next()) |raw_tok| {
        const tok = std.mem.trim(u8, raw_tok, ".,;:!?()[]{}<>\"'");
        if (tok.len == 0) continue;
        token_count += 1;
        current_sentence_tokens += 1;

        const h = std.hash.Wyhash.hash(0, tok);
        const bucket: usize = @intCast(h & 255);
        if (!unique_buckets[bucket]) {
            unique_buckets[bucket] = true;
            unique_hits += 1;
        }

        if (raw_tok.len > 0) {
            const last_ch = raw_tok[raw_tok.len - 1];
            if ((last_ch == '.' or last_ch == '!' or last_ch == '?') and sentence_idx < sentence_lengths.len) {
                sentence_lengths[sentence_idx] = current_sentence_tokens;
                sentence_idx += 1;
                current_sentence_tokens = 0;
            }
        }
    }
    if (current_sentence_tokens > 0 and sentence_idx < sentence_lengths.len) {
        sentence_lengths[sentence_idx] = current_sentence_tokens;
        sentence_idx += 1;
    }

    var burstiness_permille: u16 = 500;
    if (sentence_idx >= 2) {
        var sum_len: f32 = 0.0;
        for (sentence_lengths[0..sentence_idx]) |slen| {
            sum_len += @floatFromInt(slen);
        }
        const mean_len = sum_len / @as(f32, @floatFromInt(sentence_idx));
        var var_sum: f32 = 0.0;
        for (sentence_lengths[0..sentence_idx]) |slen| {
            const diff = @as(f32, @floatFromInt(slen)) - mean_len;
            var_sum += diff * diff;
        }
        const std_len = @sqrt(var_sum / @as(f32, @floatFromInt(sentence_idx)));
        const cv = std_len / @max(1.0, mean_len);
        burstiness_permille = @intFromFloat(std.math.clamp(cv * 650.0, 50.0, 1000.0));
    } else if (entropy > 3.8 and entropy < 5.1) {
        burstiness_permille = 580;
    }

    const unique_ratio: u16 = if (token_count == 0)
        0
    else
        @intCast(@min(1000, (unique_hits * 1000) / @min(token_count, 256)));

    var heading_spans: u32 = 0;
    for (spans) |sp| {
        if (sp.heading_level > 0) heading_spans += 1;
    }
    const heading_density: u16 = if (spans.len == 0)
        0
    else
        @intCast(@min(1000, (heading_spans * 1000) / @as(u32, @intCast(spans.len))));

    var anchor_bytes: usize = 0;
    var nofollow_count: usize = 0;
    for (links) |lnk| {
        anchor_bytes += lnk.anchor_text.len;
        if (lnk.rel_nofollow) nofollow_count += 1;
    }

    const link_ratio: u16 = if (body_text.len == 0)
        1000
    else
        @intCast(@min(1000, (anchor_bytes * 1000) / body_text.len));

    const nofollow_ratio: u16 = if (links.len == 0)
        0
    else
        @intCast(@min(1000, (nofollow_count * 1000) / links.len));

    const has_title: u16 = if (title.len >= 4) 250 else 0;
    const has_paragraphs: u16 = if (spans.len >= 2) 450 else 150;
    const coherence: u16 = @min(1000, has_title + has_paragraphs + @min(300, unique_ratio / 3));

    return .{
        .text_byte_length = @intCast(@min(std.math.maxInt(u32), body_text.len)),
        .unique_token_ratio_permille = unique_ratio,
        .character_entropy_milli = @intFromFloat(@max(0.0, entropy * 1000.0)),
        .heading_density_permille = heading_density,
        .link_to_text_ratio_permille = link_ratio,
        .nofollow_link_ratio_permille = nofollow_ratio,
        .perplexity_burstiness_permille = burstiness_permille,
        .structural_coherence_permille = coherence,
        .source_originality_permille = if (is_unique_dedup) 850 else 200,
    };
}
