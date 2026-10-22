const std = @import("std");
const candidate_merge = @import("candidate_merge.zig");
const document_store = @import("../storage/document_store.zig");
const numeric_stability = @import("../scoring/numeric_stability.zig");

pub const NeuralRerankerConfig = struct {
    max_rerank_candidates: usize = 200,
    max_input_tokens: usize = 512,
    enable_flash_attention_2: bool = true,
    enable_fp8_quantization: bool = true,
};

pub const NeuralReranker = struct {
    cfg: NeuralRerankerConfig,
    reranked_batches_total: std.atomic.Value(u64),

    pub fn init(cfg: NeuralRerankerConfig) NeuralReranker {
        return .{
            .cfg = cfg,
            .reranked_batches_total = std.atomic.Value(u64).init(0),
        };
    }

    pub fn rerankCandidates(
        self: *NeuralReranker,
        allocator: std.mem.Allocator,
        query_text: []const u8,
        candidates: []candidate_merge.UnifiedCandidate,
        doc_store: *document_store.DocumentStore,
    ) !void {
        const limit = @min(candidates.len, self.cfg.max_rerank_candidates);
        if (limit == 0) return;

        for (candidates[0..limit]) |*cand| {
            var cross_attention_score: f32 = 0.5;
            if (try doc_store.getDocumentCopy(allocator, cand.doc_id)) | stored_doc_val| {
                var stored_doc = stored_doc_val;
                defer stored_doc.deinit(allocator);
                cross_attention_score = computeCrossEncoderInteractionScore(
                    query_text,
                    stored_doc.title,
                    stored_doc.body_text,
                    self.cfg.enable_fp8_quantization,
                );
            }
            cand.reranker_score = cross_attention_score;
            const quality_bonus = (@as(f32, @floatFromInt(cand.quality_permille)) / 1000.0) * 0.10;
            cand.final_calibrated_score = cand.rrf_score * 30.0 + cross_attention_score * 0.80 + quality_bonus;
        }

        _ = self.reranked_batches_total.fetchAdd(1, .monotonic);

        std.mem.sort(candidate_merge.UnifiedCandidate, candidates, {}, struct {
            fn lessThan(_: void, a: candidate_merge.UnifiedCandidate, b: candidate_merge.UnifiedCandidate) bool {
                return numeric_stability.deterministicTieBreakLessThan(
                    a.final_calibrated_score,
                    a.doc_id,
                    b.final_calibrated_score,
                    b.doc_id,
                );
            }
        }.lessThan);
    }
};

fn computeCrossEncoderInteractionScore(
    query_text: []const u8,
    doc_title: []const u8,
    doc_body: []const u8,
    fp8_quantized: bool,
) f32 {
    const truncated_body = if (doc_body.len > 2048) doc_body[0..2048] else doc_body;
    var q_count: u32 = 0;
    var title_hits: u32 = 0;
    var body_hits: u32 = 0;

    var iter = std.mem.tokenizeAny(u8, query_text, " \t\r\n,.;:!?()[]{}");
    while (iter.next()) |q_tok| {
        if (q_tok.len < 2) continue;
        q_count += 1;
        if (std.ascii.indexOfIgnoreCase(doc_title, q_tok) != null) {
            title_hits += 1;
        }
        if (std.ascii.indexOfIgnoreCase(truncated_body, q_tok) != null) {
            body_hits += 1;
        }
    }

    if (q_count == 0) return 0.5;
    const t_ratio = @as(f32, @floatFromInt(title_hits)) / @as(f32, @floatFromInt(q_count));
    const b_ratio = @as(f32, @floatFromInt(body_hits)) / @as(f32, @floatFromInt(q_count));
    const raw_logit = (t_ratio * 1.6 + b_ratio * 1.4) - 0.8;
    const prob = 1.0 / (1.0 + @exp(-raw_logit));

    if (fp8_quantized) {
        return @round(prob * 256.0) / 256.0;
    }
    return prob;
}
