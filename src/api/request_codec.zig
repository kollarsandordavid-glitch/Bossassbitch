const std = @import("std");

pub const SearchRequestPayload = struct {
    query_text: []const u8 = "",
    top_k: u32 = 10,
    candidate_pool_k: u32 = 500,
    ranking_mode: []const u8 = "hybrid",
    deadline_ms: u64 = 85,
    include_highlights: bool = true,
    verify_claims: bool = true,
    extract_entities: bool = false,
    min_quality_permille: u16 = 0,
};

pub const IngestRequestPayload = struct {
    url: []const u8 = "",
    title: []const u8 = "",
    html_or_body: []const u8 = "",
    language: []const u8 = "en",
    doc_type: []const u8 = "web_page",
    priority: bool = false,
};

pub const ResearchRequestPayload = struct {
    query_text: []const u8 = "",
    max_steps: u32 = 3,
    deadline_ms: u64 = 60000,
};

pub const HighlightsRequestPayload = struct {
    query_text: []const u8 = "",
    doc_id: u64 = 0,
    max_highlights: u32 = 3,
};

pub const EntitiesRequestPayload = struct {
    text: []const u8 = "",
    doc_id: u64 = 0,
    run_edge_case_rubric: bool = false,
};

pub const ModelRefreshRequestPayload = struct {
    checkpoint_file: []const u8 = "",
    model_version: u32 = 1002,
    curriculum_stage: u8 = 2,
};

pub fn extractJsonStringField(allocator: std.mem.Allocator, body: []const u8, field_name: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidInput;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInput;
    if (parsed.value.object.get(field_name)) |val| {
        if (val == .string) {
            return try allocator.dupe(u8, val.string);
        }
    }
    return null;
}

pub fn parseSearchRequest(allocator: std.mem.Allocator, body: []const u8) !SearchRequestPayload {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidInput;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInput;
    const obj = parsed.value.object;

    const q_val = obj.get("query_text") orelse obj.get("query") orelse return error.InvalidInput;
    if (q_val != .string or q_val.string.len == 0) return error.InvalidInput;

    var out = SearchRequestPayload{
        .query_text = try allocator.dupe(u8, q_val.string),
    };
    if (obj.get("top_k")) |v| {
        if (v == .integer and v.integer > 0) out.top_k = @intCast(@min(1000, v.integer));
    }
    if (obj.get("candidate_pool_k")) |v| {
        if (v == .integer and v.integer == 5000) out.candidate_pool_k = 5000;
    }
    if (obj.get("ranking_mode")) |v| {
        if (v == .string) out.ranking_mode = try allocator.dupe(u8, v.string);
    }
    if (obj.get("deadline_ms")) |v| {
        if (v == .integer and v.integer >= 5) out.deadline_ms = @intCast(@min(180000, v.integer));
    }
    if (obj.get("include_highlights")) |v| {
        if (v == .bool) out.include_highlights = v.bool;
    }
    if (obj.get("verify_claims")) |v| {
        if (v == .bool) out.verify_claims = v.bool;
    }
    if (obj.get("extract_entities")) |v| {
        if (v == .bool) out.extract_entities = v.bool;
    }
    if (obj.get("min_quality_permille")) |v| {
        if (v == .integer and v.integer >= 0) out.min_quality_permille = @intCast(@min(1000, v.integer));
    }
    return out;
}

pub fn parseIngestRequest(allocator: std.mem.Allocator, body: []const u8) !IngestRequestPayload {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidInput;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInput;
    const obj = parsed.value.object;

    const url_v = obj.get("url") orelse obj.get("canonical_url") orelse return error.InvalidInput;
    const body_v = obj.get("html") orelse obj.get("body_text") orelse obj.get("content") orelse return error.InvalidInput;
    if (url_v != .string or body_v != .string or url_v.string.len == 0) return error.InvalidInput;

    var out = IngestRequestPayload{
        .url = try allocator.dupe(u8, url_v.string),
        .html_or_body = try allocator.dupe(u8, body_v.string),
    };
    if (obj.get("title")) |v| {
        if (v == .string) out.title = try allocator.dupe(u8, v.string);
    }
    if (obj.get("language")) |v| {
        if (v == .string) out.language = try allocator.dupe(u8, v.string);
    }
    if (obj.get("doc_type")) |v| {
        if (v == .string) out.doc_type = try allocator.dupe(u8, v.string);
    }
    if (obj.get("priority")) |v| {
        if (v == .bool) out.priority = v.bool;
    }
    return out;
}

pub fn parseResearchRequest(allocator: std.mem.Allocator, body: []const u8) !ResearchRequestPayload {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidInput;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInput;
    const obj = parsed.value.object;

    const q_val = obj.get("query_text") orelse obj.get("query") orelse return error.InvalidInput;
    if (q_val != .string or q_val.string.len == 0) return error.InvalidInput;

    var out = ResearchRequestPayload{
        .query_text = try allocator.dupe(u8, q_val.string),
    };
    if (obj.get("max_steps")) |v| {
        if (v == .integer and v.integer >= 1) out.max_steps = @intCast(@min(12, v.integer));
    }
    if (obj.get("deadline_ms")) |v| {
        if (v == .integer and v.integer >= 100) out.deadline_ms = @intCast(@min(180000, v.integer));
    }
    return out;
}

pub fn parseHighlightsRequest(allocator: std.mem.Allocator, body: []const u8) !HighlightsRequestPayload {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidInput;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInput;
    const obj = parsed.value.object;

    const q_val = obj.get("query_text") orelse obj.get("query") orelse return error.InvalidInput;
    const d_val = obj.get("doc_id") orelse return error.InvalidInput;
    if (q_val != .string or d_val != .integer or d_val.integer <= 0) return error.InvalidInput;

    var out = HighlightsRequestPayload{
        .query_text = try allocator.dupe(u8, q_val.string),
        .doc_id = @intCast(d_val.integer),
    };
    if (obj.get("max_highlights")) |v| {
        if (v == .integer and v.integer >= 1) out.max_highlights = @intCast(@min(10, v.integer));
    }
    return out;
}

pub fn parseEntitiesRequest(allocator: std.mem.Allocator, body: []const u8) !EntitiesRequestPayload {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidInput;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInput;
    const obj = parsed.value.object;

    var out = EntitiesRequestPayload{};
    if (obj.get("text")) |v| {
        if (v == .string) out.text = try allocator.dupe(u8, v.string);
    }
    if (obj.get("doc_id")) |v| {
        if (v == .integer and v.integer >= 0) out.doc_id = @intCast(v.integer);
    }
    if (obj.get("run_edge_case_rubric")) |v| {
        if (v == .bool) out.run_edge_case_rubric = v.bool;
    }
    if (out.text.len == 0 and out.doc_id == 0 and !out.run_edge_case_rubric) {
        return error.InvalidInput;
    }
    return out;
}

pub fn parseModelRefreshRequest(allocator: std.mem.Allocator, body: []const u8) !ModelRefreshRequestPayload {
    if (body.len == 0) return ModelRefreshRequestPayload{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidInput;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInput;
    const obj = parsed.value.object;

    var out = ModelRefreshRequestPayload{};
    if (obj.get("checkpoint_file")) |v| {
        if (v == .string) out.checkpoint_file = try allocator.dupe(u8, v.string);
    }
    if (obj.get("model_version")) |v| {
        if (v == .integer and v.integer >= 1) out.model_version = @intCast(v.integer);
    }
    if (obj.get("curriculum_stage")) |v| {
        if (v == .integer and v.integer >= 1 and v.integer <= 8) out.curriculum_stage = @intCast(v.integer);
    }
    return out;
}
