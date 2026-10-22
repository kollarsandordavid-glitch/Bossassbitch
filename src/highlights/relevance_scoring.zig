const std = @import("std");

pub const PassageScoreComponents = struct {
    lexical_support: f32,
    semantic_relevance: f32,
    coverage_ratio: f32,
    coherence_score: f32,
    redundancy_penalty: f32,
    combined_score: f32,
};

pub fn scorePassageAgainstQuery(
    query_text: []const u8,
    passage_text: []const u8,
    already_selected_passages: []const []const u8,
) PassageScoreComponents {
    var q_count: u32 = 0;
    var matched_q: u32 = 0;
    var total_occurrences: u32 = 0;

    var q_iter = std.mem.tokenizeAny(u8, query_text, " \t\r\n,.;:!?()[]{}");
    while (q_iter.next()) |q_tok| {
        if (q_tok.len < 2) continue;
        q_count += 1;
        if (std.ascii.indexOfIgnoreCase(passage_text, q_tok)) |first_idx| {
            matched_q += 1;
            total_occurrences += 1;
            if (std.ascii.indexOfIgnoreCasePos(passage_text, first_idx + q_tok.len, q_tok) != null) {
                total_occurrences += 1;
            }
        }
    }

    const coverage = if (q_count == 0) 0.5 else @as(f32, @floatFromInt(matched_q)) / @as(f32, @floatFromInt(q_count));
    const lex_support = std.math.clamp(@as(f32, @floatFromInt(total_occurrences)) / @as(f32, @floatFromInt(@max(1, q_count * 2))), 0.0, 1.0);
    const sem_relevance = std.math.clamp(coverage * 0.75 + lex_support * 0.25, 0.0, 1.0);

    const len_f: f32 = @floatFromInt(passage_text.len);
    const coherence: f32 = if (len_f >= 48.0 and len_f <= 480.0) 0.90 else 0.65;

    var max_redundancy: f32 = 0.0;
    for (already_selected_passages) |sel| {
        if (std.mem.eql(u8, sel, passage_text)) {
            max_redundancy = 1.0;
            break;
        }
        const min_len = @min(sel.len, passage_text.len);
        if (min_len > 16 and std.mem.eql(u8, sel[0..16], passage_text[0..16])) {
            max_redundancy = @max(max_redundancy, 0.6);
        }
    }

    const combined = (sem_relevance * 0.40) + (lex_support * 0.25) + (coverage * 0.20) + (coherence * 0.15) - (max_redundancy * 0.50);

    return .{
        .lexical_support = lex_support,
        .semantic_relevance = sem_relevance,
        .coverage_ratio = coverage,
        .coherence_score = coherence,
        .redundancy_penalty = max_redundancy,
        .combined_score = combined,
    };
}
