const std = @import("std");
const request_codec = @import("request_codec.zig");
const response_codec = @import("response_codec.zig");
const highlight_extractor = @import("../highlights/highlight_extractor.zig");
const document_store = @import("../storage/document_store.zig");
const http_server = @import("../network/http_server.zig");

pub fn handleHighlightsRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
    doc_store: *document_store.DocumentStore,
) !http_server.OutgoingHttpResponse {
    const req = request_codec.parseHighlightsRequest(allocator, body) catch {
        return .{
            .status_code = 400,
            .content_type = "application/json",
            .body = try response_codec.encodeErrorJson(allocator, "invalid_highlights_request", "Missing query_text or doc_id"),
        };
    };

    const doc_opt = try doc_store.getDocumentCopy(allocator, req.doc_id);
    if (doc_opt == null) {
        return .{
            .status_code = 404,
            .content_type = "application/json",
            .body = try response_codec.encodeErrorJson(allocator, "document_not_found", "Requested doc_id does not exist in document store"),
        };
    }
    var doc = doc_opt.?;
    defer doc.deinit(allocator);

    const extractor = highlight_extractor.HighlightExtractor.init();
    const highlights = try extractor.extractHighlightsForDocument(
        allocator,
        req.query_text,
        doc.doc_id,
        doc.canonical_url,
        doc.title,
        doc.body_text,
        req.max_highlights,
    );
    defer {
        for (highlights) |*h| h.deinit(allocator);
        allocator.free(highlights);
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.print("{{\"status\":\"ok\",\"doc_id\":{d},\"highlights\":[", .{doc.doc_id});
    for (highlights, 0..) |hl, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.print("{{\"doc_id\":{d},\"byte_start\":{d},\"byte_end\":{d},\"score\":{d:.4},\"source_verified\":{},\"source_url\":", .{
            hl.doc_id,
            hl.byte_start,
            hl.byte_end,
            hl.score,
            hl.source_verified,
        });
        try response_codec.writeJsonEscaped(w, hl.source_url);
        try w.writeAll(",\"parent_heading\":");
        try response_codec.writeJsonEscaped(w, hl.parent_heading);
        try w.writeAll(",\"passage_text\":");
        try response_codec.writeJsonEscaped(w, hl.passage_text);
        try w.writeByte('}');
    }
    try w.writeAll("]}");

    return .{
        .status_code = 200,
        .content_type = "application/json",
        .body = try out.toOwnedSlice(),
    };
}
