const std = @import("std");
const query_dag = @import("../orchestration/query_dag.zig");
const document_store = @import("../storage/document_store.zig");

pub fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch >= 0x20 and ch < 0x7f) {
                    try writer.writeByte(ch);
                } else {
                    try writer.writeByte(' ');
                }
            },
        }
    }
    try writer.writeByte('"');
}

pub fn encodeErrorJson(
    allocator: std.mem.Allocator,
    error_code: []const u8,
    message: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"status\":\"error\",\"error_code\":");
    try writeJsonEscaped(w, error_code);
    try w.writeAll(",\"message\":");
    try writeJsonEscaped(w, message);
    try w.writeByte('}');
    return out.toOwnedSlice();
}

pub fn encodeSearchDagResponseJson(
    allocator: std.mem.Allocator,
    dag_res: *const query_dag.DagExecutionResult,
    doc_store: *document_store.DocumentStore,
    cache_hit: bool,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.print(
        "{{\"status\":\"ok\",\"route_strategy\":\"{s}\",\"index_generation\":{d},\"model_version\":{d},\"elapsed_ms\":{d},\"selected_nprobe\":{d},\"widened_probe_used\":{},\"retrieval_complete\":{},\"cache_hit\":{},\"results\":[",
        .{
            dag_res.routing_decision.strategy.toString(),
            dag_res.index_generation,
            dag_res.model_version,
            dag_res.total_elapsed_ms,
            dag_res.selected_nprobe,
            dag_res.widened_probe_used,
            dag_res.retrieval_complete,
            cache_hit,
        },
    );

    for (dag_res.ranked_candidates, 0..) |cand, idx| {
        if (idx > 0) try w.writeByte(',');
        var url: []const u8 = "";
        var title: []const u8 = "";
        var snippet: []const u8 = "";
        var doc_opt = try doc_store.getDocumentCopy(allocator, cand.doc_id);
        defer if (doc_opt) |*d| d.deinit(allocator);
        if (doc_opt) |d| {
            url = d.canonical_url;
            title = d.title;
            snippet = if (d.body_text.len > 220) d.body_text[0..220] else d.body_text;
        }

        try w.print("{{\"rank\":{d},\"doc_id\":{d},\"canonical_url\":", .{ idx + 1, cand.doc_id });
        try writeJsonEscaped(w, url);
        try w.writeAll(",\"title\":");
        try writeJsonEscaped(w, title);
        try w.writeAll(",\"snippet\":");
        try writeJsonEscaped(w, snippet);
        try w.print(
            ",\"dense_score\":{d:.4},\"sparse_score\":{d:.4},\"rrf_score\":{d:.4},\"reranker_score\":{d:.4},\"final_score\":{d:.4}}}",
            .{ cand.dense_score, cand.sparse_score, cand.rrf_score, cand.reranker_score, cand.final_calibrated_score },
        );
    }

    try w.writeAll("],\"highlights\":[");
    for (dag_res.highlights, 0..) |hl, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.print("{{\"doc_id\":{d},\"byte_start\":{d},\"byte_end\":{d},\"score\":{d:.4},\"source_verified\":{},\"source_url\":", .{
            hl.doc_id,
            hl.byte_start,
            hl.byte_end,
            hl.score,
            hl.source_verified,
        });
        try writeJsonEscaped(w, hl.source_url);
        try w.writeAll(",\"parent_heading\":");
        try writeJsonEscaped(w, hl.parent_heading);
        try w.writeAll(",\"passage_text\":");
        try writeJsonEscaped(w, hl.passage_text);
        try w.writeByte('}');
    }

    try w.writeAll("],\"verified_claims\":[");
    for (dag_res.verified_claims, 0..) |vc, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.print("{{\"doc_id\":{d},\"status\":\"{s}\",\"confidence_permille\":{d},\"contradiction\":{},\"source_url\":", .{
            vc.doc_id,
            vc.status.toString(),
            vc.confidence_permille,
            vc.contradiction_detected,
        });
        try writeJsonEscaped(w, vc.source_url);
        try w.writeAll(",\"evidence_span\":");
        try writeJsonEscaped(w, vc.evidence_span);
        try w.writeByte('}');
    }

    try w.writeAll("],\"entities\":[");
    for (dag_res.entities, 0..) |ent, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.print("{{\"doc_id\":{d},\"category\":\"{s}\",\"confidence_permille\":{d},\"surface\":", .{
            ent.source_doc_id,
            ent.category.toString(),
            ent.confidence_permille,
        });
        try writeJsonEscaped(w, ent.surface_form);
        try w.writeAll(",\"canonical\":");
        try writeJsonEscaped(w, ent.normalized_canonical);
        try w.writeByte('}');
    }
    try w.writeAll("]}");

    return out.toOwnedSlice();
}
