const std = @import("std");
const query_dag = @import("query_dag.zig");
const deadlines = @import("deadlines.zig");
const branch_cancellation = @import("branch_cancellation.zig");
const speculative_execution = @import("speculative_execution.zig");
const query_parser = @import("../retrieval/query_parser.zig");
const query_router = @import("../retrieval/query_router.zig");
const sparse_index = @import("../retrieval/sparse_index.zig");
const bm25 = @import("../retrieval/bm25.zig");
const dense_search = @import("../retrieval/dense_search.zig");
const candidate_merge = @import("../retrieval/candidate_merge.zig");
const rrf = @import("../retrieval/reciprocal_rank_fusion.zig");
const reranker = @import("../retrieval/reranker.zig");
const citation_verifier = @import("../retrieval/citation_verifier.zig");
const highlight_extractor = @import("../highlights/highlight_extractor.zig");
const entity_classifier = @import("../models/entity_classifier.zig");
const embedding_service = @import("../models/embedding_service.zig");
const vector_index = @import("../index/vector_index.zig");
const filter_engine = @import("../index/filter_engine.zig");
const document_store = @import("../storage/document_store.zig");
const time_util = @import("../util/time.zig");

pub const DagExecutionInput = struct {
    query_text: []const u8,
    ranking_mode: []const u8,
    top_k: u32,
    candidate_pool_k: u32,
    deadline_ms: u64,
    include_highlights: bool,
    verify_claims: bool,
    extract_entities: bool,
    filters: filter_engine.CompoundFilterCriteria,
};

pub const DagScheduler = struct {
    embedding_svc: *embedding_service.EmbeddingService,
    vec_index: *vector_index.DistributedVectorIndex,
    sparse_idx: *sparse_index.SparseInvertedIndex,
    doc_store: *document_store.DocumentStore,
    neural_reranker: *reranker.NeuralReranker,
    entity_cls: *entity_classifier.EntityClassifier,

    pub fn executeQueryDag(
        self: *DagScheduler,
        allocator: std.mem.Allocator,
        input: DagExecutionInput,
    ) !query_dag.DagExecutionResult {
        const root_sw = time_util.Stopwatch.start();
        var states: [9]query_dag.DagNodeState = [_]query_dag.DagNodeState{.pending} ** 9;
        var durations: [9]u64 = [_]u64{0} ** 9;

        const budget = deadlines.StageBudgetPlan.build(
            input.deadline_ms,
            35,
            40,
            35,
            20,
            25,
        );
        var cancel_ctrl = branch_cancellation.BranchCancellationController.init(input.deadline_ms);

        const router_sw = time_util.Stopwatch.start();
        var parsed_q = try query_parser.parseQuery(allocator, input.query_text);
        defer parsed_q.deinit(allocator);

        var decision = query_router.routeQuery(
            &parsed_q,
            input.ranking_mode,
            input.filters,
            input.candidate_pool_k,
        );
        const spec_dec = speculative_execution.evaluateSpeculativeExecution(
            decision,
            budget.remainingTotalMillis(),
            18,
        );
        if (spec_dec.launch_speculative_sparse) decision.execute_sparse_branch = true;
        if (spec_dec.launch_speculative_dense) decision.execute_dense_branch = true;
        states[0] = .completed;
        durations[0] = router_sw.elapsedMicros();

        const visibility = self.vec_index.consistency_coord.acquireReadBoundary();

        var sparse_results: []bm25.SparseScoredCandidate = &.{};
        var owns_sparse = false;
        defer if (owns_sparse) allocator.free(sparse_results);

        if (decision.execute_sparse_branch) {
            const s_sw = time_util.Stopwatch.start();
            sparse_results = try bm25.searchBm25TopK(
                allocator,
                self.sparse_idx,
                &parsed_q,
                .{},
                decision.candidate_pool_k,
            );
            owns_sparse = true;
            states[1] = .completed;
            durations[1] = s_sw.elapsedMicros();
        } else {
            states[1] = .skipped;
        }

        var dense_resp = dense_search.DenseSearchResponse{
            .candidates = &.{},
            .selected_nprobe = 0,
            .widened_fallback_used = false,
            .is_complete = true,
        };
        var owns_dense = false;
        defer if (owns_dense) dense_resp.deinit(allocator);

        if (decision.execute_dense_branch) {
            const d_sw = time_util.Stopwatch.start();
            const q_emb = try self.embedding_svc.embedQueryText(input.query_text);
            dense_resp = try dense_search.executeDenseVectorSearch(
                allocator,
                self.vec_index,
                &q_emb.retained_embedding,
                &q_emb.quantized_binary.packed_bytes,
                input.filters,
                decision.candidate_pool_k,
                &cancel_ctrl.branch_tokens[2],
            );
            owns_dense = true;
            states[2] = .completed;
            durations[2] = d_sw.elapsedMicros();
        } else {
            states[2] = .skipped;
        }

        cancel_ctrl.cancelNonEssentialAfterSufficientCandidates(
            dense_resp.candidates.len + sparse_results.len,
            input.top_k,
        );
        states[3] = if (cancel_ctrl.branch_tokens[3].isCancelled()) .cancelled else .completed;

        const f_sw = time_util.Stopwatch.start();
        var merged = try candidate_merge.deduplicateAndCombinePools(
            allocator,
            dense_resp.candidates,
            sparse_results,
            decision.candidate_pool_k,
        );
        errdefer allocator.free(merged);

        rrf.applyReciprocalRankFusion(merged, .{});
        states[4] = .completed;
        durations[4] = f_sw.elapsedMicros();

        if (decision.execute_rerank_branch and !budget.isHardDeadlineExpired()) {
            const r_sw = time_util.Stopwatch.start();
            try self.neural_reranker.rerankCandidates(
                allocator,
                input.query_text,
                merged,
                self.doc_store,
            );
            states[5] = .completed;
            durations[5] = r_sw.elapsedMicros();
        } else {
            states[5] = if (budget.isHardDeadlineExpired()) .cancelled else .skipped;
        }

        const final_k = @min(merged.len, @as(usize, @intCast(@max(1, input.top_k))));
        const top_candidates = try allocator.dupe(candidate_merge.UnifiedCandidate, merged[0..final_k]);
        allocator.free(merged);
        errdefer allocator.free(top_candidates);

        var highlights_list = std.ArrayList(highlight_extractor.GroundedHighlight).init(allocator);
        errdefer {
            for (highlights_list.items) |*h| h.deinit(allocator);
            highlights_list.deinit();
        }

        if (input.include_highlights and !budget.isHardDeadlineExpired()) {
            const h_sw = time_util.Stopwatch.start();
            const extractor = highlight_extractor.HighlightExtractor.init();
            for (top_candidates[0..@min(top_candidates.len, 5)]) |cand| {
                if (try self.doc_store.getDocumentCopy(allocator, cand.doc_id)) |doc_val| {
                    var doc = doc_val;
                    defer doc.deinit(allocator);
                    const doc_hl = try extractor.extractHighlightsForDocument(
                        allocator,
                        input.query_text,
                        doc.doc_id,
                        doc.canonical_url,
                        doc.title,
                        doc.body_text,
                        2,
                    );
                    defer allocator.free(doc_hl);
                    try highlights_list.appendSlice(doc_hl);
                }
            }
            states[6] = .completed;
            durations[6] = h_sw.elapsedMicros();
        } else {
            states[6] = .skipped;
        }

        var claims_list = std.ArrayList(citation_verifier.VerifiedClaimRecord).init(allocator);
        errdefer {
            for (claims_list.items) |*c| c.deinit(allocator);
            claims_list.deinit();
        }

        if (input.verify_claims and !budget.isHardDeadlineExpired()) {
            const v_sw = time_util.Stopwatch.start();
            const verifier = citation_verifier.CitationVerifier.init();
            for (top_candidates[0..@min(top_candidates.len, 5)]) |cand| {
                if (try self.doc_store.getDocumentCopy(allocator, cand.doc_id)) |doc_val| {
                    var doc = doc_val;
                    defer doc.deinit(allocator);
                    const v_rec = try verifier.verifyClaimAgainstDocument(
                        allocator,
                        input.query_text,
                        doc.doc_id,
                        doc.canonical_url,
                        doc.body_text,
                    );
                    try claims_list.append(v_rec);
                }
            }
            states[7] = .completed;
            durations[7] = v_sw.elapsedMicros();
        } else {
            states[7] = .skipped;
        }

        var entities_list = std.ArrayList(entity_classifier.ExtractedEntity).init(allocator);
        errdefer {
            for (entities_list.items) |*e| e.deinit(allocator);
            entities_list.deinit();
        }

        if (input.extract_entities and !budget.isHardDeadlineExpired()) {
            const e_sw = time_util.Stopwatch.start();
            for (top_candidates[0..@min(top_candidates.len, 5)]) |cand| {
                if (try self.doc_store.getDocumentCopy(allocator, cand.doc_id)) |doc_val| {
                    var doc = doc_val;
                    defer doc.deinit(allocator);
                    const ents = try self.entity_cls.extractEntities(allocator, doc.body_text, doc.doc_id);
                    defer allocator.free(ents);
                    try entities_list.appendSlice(ents);
                }
            }
            states[8] = .completed;
            durations[8] = e_sw.elapsedMicros();
        } else {
            states[8] = .skipped;
        }

        return .{
            .routing_decision = decision,
            .ranked_candidates = top_candidates,
            .highlights = try highlights_list.toOwnedSlice(),
            .verified_claims = try claims_list.toOwnedSlice(),
            .entities = try entities_list.toOwnedSlice(),
            .node_states = states,
            .node_durations_micros = durations,
            .total_elapsed_ms = root_sw.elapsedMillis(),
            .selected_nprobe = dense_resp.selected_nprobe,
            .widened_probe_used = dense_resp.widened_fallback_used,
            .retrieval_complete = dense_resp.is_complete and !budget.isHardDeadlineExpired(),
            .index_generation = visibility.generation_id,
            .model_version = visibility.model_version,
        };
    }
};
