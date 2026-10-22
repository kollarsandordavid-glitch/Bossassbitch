const std = @import("std");
const sparse_index = @import("sparse_index.zig");
const query_parser = @import("query_parser.zig");
const numeric_stability = @import("../scoring/numeric_stability.zig");

pub const Bm25Parameters = struct {
    k1: f32 = 1.2,
    b: f32 = 0.75,
    title_weight: f32 = 2.5,
    heading_weight: f32 = 1.8,
    body_weight: f32 = 1.0,
    url_weight: f32 = 1.5,
    anchor_weight: f32 = 1.6,
    metadata_weight: f32 = 1.2,
};

pub const SparseScoredCandidate = struct {
    doc_id: u64,
    bm25_score: f32,
    matched_terms: u16,
};

pub fn searchBm25TopK(
    allocator: std.mem.Allocator,
    index: *sparse_index.SparseInvertedIndex,
    parsed_query: *const query_parser.ParsedQuery,
    params: Bm25Parameters,
    top_k: usize,
) ![]SparseScoredCandidate {
    index.mutex.lock();
    defer index.mutex.unlock();

    var doc_scores = std.AutoHashMap(u64, SparseScoredCandidate).init(allocator);
    defer doc_scores.deinit();

    const n_docs_f: f32 = @floatFromInt(@max(1, index.total_docs));
    const avg_dl = index.averageDocLength();

    for (parsed_query.terms) |term| {
        const plist = index.postings.get(term.term_hash) orelse continue;
        const df_f: f32 = @floatFromInt(plist.items.len);
        const idf = @log(1.0 + (n_docs_f - df_f + 0.5) / (df_f + 0.5));

        for (plist.items) |entry| {
            const dl_u32 = index.doc_lengths.get(entry.doc_id) orelse 100;
            const dl_f: f32 = @floatFromInt(@max(1, dl_u32));

            const weighted_tf: f32 =
                @as(f32, @floatFromInt(entry.title_tf)) * params.title_weight +
                @as(f32, @floatFromInt(entry.heading_tf)) * params.heading_weight +
                @as(f32, @floatFromInt(entry.body_tf)) * params.body_weight +
                @as(f32, @floatFromInt(entry.url_tf)) * params.url_weight +
                @as(f32, @floatFromInt(entry.anchor_tf)) * params.anchor_weight +
                @as(f32, @floatFromInt(entry.metadata_tf)) * params.metadata_weight;

            const norm_denom = weighted_tf + params.k1 * (1.0 - params.b + params.b * (dl_f / avg_dl));
            var term_score = idf * ((weighted_tf * (params.k1 + 1.0)) / @max(1e-6, norm_denom));
            if (term.is_exact_phrase_member and entry.title_tf > 0) {
                term_score *= 1.25;
            }

            const gop = try doc_scores.getOrPut(entry.doc_id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .doc_id = entry.doc_id,
                    .bm25_score = term_score,
                    .matched_terms = 1,
                };
            } else {
                gop.value_ptr.bm25_score += term_score;
                gop.value_ptr.matched_terms +|= 1;
            }
        }
    }

    var results = std.ArrayList(SparseScoredCandidate).init(allocator);
    errdefer results.deinit();

    var it = doc_scores.valueIterator();
    while (it.next()) |cand| {
        try results.append(cand.*);
    }

    std.mem.sort(SparseScoredCandidate, results.items, {}, struct {
        fn lessThan(_: void, a: SparseScoredCandidate, b: SparseScoredCandidate) bool {
            return numeric_stability.deterministicTieBreakLessThan(a.bm25_score, a.doc_id, b.bm25_score, b.doc_id);
        }
    }.lessThan);

    if (results.items.len > top_k) {
        results.shrinkRetainingCapacity(top_k);
    }
    return results.toOwnedSlice();
}
