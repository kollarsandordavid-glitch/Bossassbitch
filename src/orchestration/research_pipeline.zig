const std = @import("std");
const dag_scheduler = @import("dag_scheduler.zig");
const citation_verifier = @import("../retrieval/citation_verifier.zig");
const time_util = @import("../util/time.zig");

pub const ResearchJobStatus = enum(u8) {
    queued = 0,
    running = 1,
    completed = 2,
    cancelled = 3,
    failed = 4,
    deadline_exceeded = 5,

    pub fn toString(self: ResearchJobStatus) []const u8 {
        return switch (self) {
            .queued => "queued",
            .running => "running",
            .completed => "completed",
            .cancelled => "cancelled",
            .failed => "failed",
            .deadline_exceeded => "deadline_exceeded",
        };
    }
};

pub const ResearchCitation = struct {
    doc_id: u64,
    canonical_url: []u8,
    title: []u8,

    pub fn deinit(self: *ResearchCitation, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_url);
        allocator.free(self.title);
    }
};

pub const ResearchJobState = struct {
    job_id: []u8,
    root_query: []u8,
    status: ResearchJobStatus,
    completed_steps: u32,
    total_steps: u32,
    subqueries: [][]u8,
    verified_claims: []citation_verifier.VerifiedClaimRecord,
    citations: []ResearchCitation,
    created_at_ms: u64,
    updated_at_ms: u64,
    deadline_ms: u64,

    pub fn deinit(self: *ResearchJobState, allocator: std.mem.Allocator) void {
        allocator.free(self.job_id);
        allocator.free(self.root_query);
        for (self.subqueries) |sq| allocator.free(sq);
        allocator.free(self.subqueries);
        for (self.verified_claims) |*vc| vc.deinit(allocator);
        allocator.free(self.verified_claims);
        for (self.citations) |*c| c.deinit(allocator);
        allocator.free(self.citations);
    }
};

pub const ResearchPipelineManager = struct {
    allocator: std.mem.Allocator,
    state_dir: []u8,
    mutex: std.Thread.Mutex,
    jobs: std.StringHashMap(ResearchJobState),
    next_job_seq: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, state_dir: []const u8) !ResearchPipelineManager {
        try std.fs.cwd().makePath(state_dir);
        return .{
            .allocator = allocator,
            .state_dir = try allocator.dupe(u8, state_dir),
            .mutex = .{},
            .jobs = std.StringHashMap(ResearchJobState).init(allocator),
            .next_job_seq = std.atomic.Value(u64).init(1),
        };
    }

    pub fn deinit(self: *ResearchPipelineManager) void {
        var it = self.jobs.valueIterator();
        while (it.next()) |job| job.deinit(self.allocator);
        self.jobs.deinit();
        self.allocator.free(self.state_dir);
    }

    pub fn startAndExecuteResearchWorkflow(
        self: *ResearchPipelineManager,
        dag: *dag_scheduler.DagScheduler,
        root_query: []const u8,
        max_steps: u32,
        deadline_ms: u64,
    ) ![]u8 {
        const seq = self.next_job_seq.fetchAdd(1, .monotonic);
        const now = time_util.nowMillis();
        const job_id = try std.fmt.allocPrint(self.allocator, "res-job-{d}-{d}", .{ now, seq });
        errdefer self.allocator.free(job_id);

        var subqueries = try self.allocator.alloc([]u8, 3);
        subqueries[0] = try self.allocator.dupe(u8, root_query);
        subqueries[1] = try std.fmt.allocPrint(self.allocator, "{s} empirical verification evidence", .{root_query});
        subqueries[2] = try std.fmt.allocPrint(self.allocator, "{s} primary source architecture", .{root_query});

        var claims = std.ArrayList(citation_verifier.VerifiedClaimRecord).init(self.allocator);
        errdefer {
            for (claims.items) |*c| c.deinit(self.allocator);
            claims.deinit();
        }
        var citations = std.ArrayList(ResearchCitation).init(self.allocator);
        errdefer {
            for (citations.items) |*c| c.deinit(self.allocator);
            citations.deinit();
        }

        var seen_docs = std.AutoHashMap(u64, void).init(self.allocator);
        defer seen_docs.deinit();

        const effective_steps: u32 = @min(@max(1, max_steps), 3);
        var step: u32 = 0;
        while (step < effective_steps) : (step += 1) {
            const sq = subqueries[step];
            var dag_res = try dag.executeQueryDag(self.allocator, .{
                .query_text = sq,
                .ranking_mode = "hybrid",
                .top_k = 5,
                .candidate_pool_k = 500,
                .deadline_ms = 90,
                .include_highlights = true,
                .verify_claims = true,
                .extract_entities = false,
                .filters = .{},
            });
            defer dag_res.deinit(self.allocator);

            for (dag_res.verified_claims) |vc| {
                try claims.append(.{
                    .claim_text = try self.allocator.dupe(u8, vc.claim_text),
                    .doc_id = vc.doc_id,
                    .source_url = try self.allocator.dupe(u8, vc.source_url),
                    .evidence_span = try self.allocator.dupe(u8, vc.evidence_span),
                    .confidence_permille = vc.confidence_permille,
                    .contradiction_detected = vc.contradiction_detected,
                    .status = vc.status,
                });
            }

            for (dag_res.ranked_candidates) |cand| {
                if (seen_docs.contains(cand.doc_id)) continue;
                try seen_docs.put(cand.doc_id, {});
                if (try dag.doc_store.getDocumentCopy(self.allocator, cand.doc_id)) |doc_val| {
                    var doc = doc_val;
                    defer doc.deinit(self.allocator);
                    try citations.append(.{
                        .doc_id = doc.doc_id,
                        .canonical_url = try self.allocator.dupe(u8, doc.canonical_url),
                        .title = try self.allocator.dupe(u8, doc.title),
                    });
                }
            }
        }

        const state = ResearchJobState{
            .job_id = try self.allocator.dupe(u8, job_id),
            .root_query = try self.allocator.dupe(u8, root_query),
            .status = .completed,
            .completed_steps = effective_steps,
            .total_steps = effective_steps,
            .subqueries = subqueries,
            .verified_claims = try claims.toOwnedSlice(),
            .citations = try citations.toOwnedSlice(),
            .created_at_ms = now,
            .updated_at_ms = time_util.nowMillis(),
            .deadline_ms = now + deadline_ms,
        };

        try self.persistJobCheckpoint(state);

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.jobs.put(state.job_id, state);

        return job_id;
    }

    fn persistJobCheckpoint(self: *ResearchPipelineManager, state: ResearchJobState) !void {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ self.state_dir, state.job_id });
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writer().print(
            "{{\"job_id\":\"{s}\",\"status\":\"{s}\",\"completed_steps\":{d},\"total_steps\":{d},\"claims\":{d},\"citations\":{d}}}",
            .{ state.job_id, state.status.toString(), state.completed_steps, state.total_steps, state.verified_claims.len, state.citations.len },
        );
    }
};
