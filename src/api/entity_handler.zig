const std = @import("std");
const request_codec = @import("request_codec.zig");
const response_codec = @import("response_codec.zig");
const entity_classifier = @import("../models/entity_classifier.zig");
const document_store = @import("../storage/document_store.zig");
const http_server = @import("../network/http_server.zig");

pub fn handleEntityExtractionRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
    classifier: *entity_classifier.EntityClassifier,
    doc_store: *document_store.DocumentStore,
) !http_server.OutgoingHttpResponse {
    const req = request_codec.parseEntitiesRequest(allocator, body) catch {
        return .{
            .status_code = 400,
            .content_type = "application/json",
            .body = try response_codec.encodeErrorJson(allocator, "invalid_entities_request", "Provide text, doc_id, or run_edge_case_rubric"),
        };
    };

    var target_text: []const u8 = req.text;
    var doc_copy_opt: ?document_store.StoredDocumentRecord = null;
    defer if (doc_copy_opt) |*d| d.deinit(allocator);

    if (target_text.len == 0 and req.doc_id > 0) {
        doc_copy_opt = try doc_store.getDocumentCopy(allocator, req.doc_id);
        if (doc_copy_opt) |d| {
            target_text = d.body_text;
        }
    }

    const entities = try classifier.extractEntities(allocator, target_text, req.doc_id);
    defer {
        for (entities) |*e| e.deinit(allocator);
        allocator.free(entities);
    }

    var rubric_obs: ?entity_classifier.EdgeCaseEvaluationObservation = null;
    if (req.run_edge_case_rubric) {
        rubric_obs = try classifier.runEdgeCaseCurationAndPersistRubric();
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"status\":\"ok\",\"entities\":[");
    for (entities, 0..) |ent, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.print("{{\"category\":\"{s}\",\"byte_offset\":{d},\"byte_length\":{d},\"confidence_permille\":{d},\"surface\":", .{
            ent.category.toString(),
            ent.byte_offset,
            ent.byte_length,
            ent.confidence_permille,
        });
        try response_codec.writeJsonEscaped(w, ent.surface_form);
        try w.writeAll(",\"canonical\":");
        try response_codec.writeJsonEscaped(w, ent.normalized_canonical);
        try w.writeByte('}');
    }
    try w.writeByte(']');

    if (rubric_obs) |obs| {
        try w.print(
            ",\"edge_case_evaluation\":{{\"case_id\":{d},\"type\":\"{s}\",\"extracted_count\":{d},\"precision_permille\":{d},\"recall_permille\":{d}}}",
            .{ obs.case_id, obs.edge_case_type, obs.extracted_count, obs.rubric_precision_permille, obs.rubric_recall_permille },
        );
    }

    try w.writeByte('}');
    return .{
        .status_code = 200,
        .content_type = "application/json",
        .body = try out.toOwnedSlice(),
    };
}
