const std = @import("std");
const request_codec = @import("request_codec.zig");
const response_codec = @import("response_codec.zig");
const workload_coordinator = @import("../orchestration/workload_coordinator.zig");
const http_server = @import("../network/http_server.zig");

pub fn handleStartResearchRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
    coord: *workload_coordinator.WorkloadCoordinator,
) !http_server.OutgoingHttpResponse {
    const req = request_codec.parseResearchRequest(allocator, body) catch {
        return .{
            .status_code = 400,
            .content_type = "application/json",
            .body = try response_codec.encodeErrorJson(allocator, "invalid_research_request", "Missing or invalid query_text"),
        };
    };

    const job_id = try coord.research_mgr.startAndExecuteResearchWorkflow(
        &coord.dag,
        req.query_text,
        req.max_steps,
        req.deadline_ms,
    );
    defer allocator.free(job_id);
    _ = coord.research_jobs_served.fetchAdd(1, .monotonic);

    return handleGetResearchStatusRequest(allocator, job_id, coord);
}

pub fn handleGetResearchStatusRequest(
    allocator: std.mem.Allocator,
    job_id: []const u8,
    coord: *workload_coordinator.WorkloadCoordinator,
) !http_server.OutgoingHttpResponse {
    coord.research_mgr.mutex.lock();
    defer coord.research_mgr.mutex.unlock();

    const state = coord.research_mgr.jobs.get(job_id) orelse {
        return .{
            .status_code = 404,
            .content_type = "application/json",
            .body = try response_codec.encodeErrorJson(allocator, "research_job_not_found", "Requested research job_id was not found"),
        };
    };

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.print(
        "{{\"schema_version\":1,\"job_id\":\"{s}\",\"status\":\"{s}\",\"completed_steps\":{d},\"total_steps\":{d},\"updated_at_ms\":{d},\"root_query\":",
        .{ state.job_id, state.status.toString(), state.completed_steps, state.total_steps, state.updated_at_ms },
    );
    try response_codec.writeJsonEscaped(w, state.root_query);
    try w.writeAll(",\"subqueries\":[");
    for (state.subqueries, 0..) |sq, idx| {
        if (idx > 0) try w.writeByte(',');
        try response_codec.writeJsonEscaped(w, sq);
    }
    try w.writeAll("],\"verified_claims\":[");
    for (state.verified_claims, 0..) |vc, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.print("{{\"doc_id\":{d},\"status\":\"{s}\",\"confidence_permille\":{d},\"claim_text\":", .{
            vc.doc_id,
            vc.status.toString(),
            vc.confidence_permille,
        });
        try response_codec.writeJsonEscaped(w, vc.claim_text);
        try w.writeAll(",\"source_url\":");
        try response_codec.writeJsonEscaped(w, vc.source_url);
        try w.writeAll(",\"evidence_span\":");
        try response_codec.writeJsonEscaped(w, vc.evidence_span);
        try w.writeByte('}');
    }
    try w.writeAll("],\"citations\":[");
    for (state.citations, 0..) |cit, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.print("{{\"doc_id\":{d},\"canonical_url\":", .{cit.doc_id});
        try response_codec.writeJsonEscaped(w, cit.canonical_url);
        try w.writeAll(",\"title\":");
        try response_codec.writeJsonEscaped(w, cit.title);
        try w.writeByte('}');
    }
    try w.writeAll("]}");

    return .{
        .status_code = 200,
        .content_type = "application/json",
        .body = try out.toOwnedSlice(),
    };
}
