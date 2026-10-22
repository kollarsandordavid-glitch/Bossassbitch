const std = @import("std");
const html_parser = @import("html_parser.zig");
const canonicalization = @import("canonicalization.zig");
const deduplication = @import("deduplication.zig");
const browser_runtime = @import("browser_runtime.zig");
const time_util = @import("../util/time.zig");

pub const ExtractedCanonicalDocument = struct {
    doc_id: u64,
    canonical_url: []u8,
    original_url: []u8,
    domain_id: u64,
    canonical_key_hash: u64,
    content_hash: u64,
    simhash: u64,
    title: []u8,
    description: []u8,
    body_text: []u8,
    language: []u8,
    fetched_at_ms: u64,
    published_at_ms: u64,
    spans: []html_parser.StructuralSpan,
    outbound_links: []html_parser.ExtractedLink,
    dedup_decision: deduplication.DeduplicationDecision,

    pub fn deinit(self: *ExtractedCanonicalDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_url);
        allocator.free(self.original_url);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.body_text);
        allocator.free(self.language);
        for (self.spans) |*s| s.deinit(allocator);
        allocator.free(self.spans);
        for (self.outbound_links) |*l| l.deinit(allocator);
        allocator.free(self.outbound_links);
    }
};

pub const DocumentExtractor = struct {
    allocator: std.mem.Allocator,
    parser: html_parser.HtmlParser,
    browser_pool: *browser_runtime.BrowserRuntimePool,
    dedup: *deduplication.DeduplicationEngine,
    next_doc_id: std.atomic.Value(u64),

    pub fn init(
        allocator: std.mem.Allocator,
        max_dom_depth: u16,
        max_nodes: u32,
        browser_pool: *browser_runtime.BrowserRuntimePool,
        dedup: *deduplication.DeduplicationEngine,
    ) DocumentExtractor {
        return .{
            .allocator = allocator,
            .parser = html_parser.HtmlParser.init(allocator, max_dom_depth, max_nodes),
            .browser_pool = browser_pool,
            .dedup = dedup,
            .next_doc_id = std.atomic.Value(u64).init(1),
        };
    }

    pub fn extractFromHtml(
        self: *DocumentExtractor,
        original_url: []const u8,
        redirect_url: ?[]const u8,
        raw_html: []const u8,
    ) !ExtractedCanonicalDocument {
        var effective_html: []u8 = undefined;
        if (browser_runtime.BrowserRuntimePool.requiresSpaRendering(raw_html)) {
            const render_res = try self.browser_pool.renderPage(original_url, raw_html);
            effective_html = render_res.rendered_html;
            for (render_res.discovered_links) |l| self.allocator.free(l);
            self.allocator.free(render_res.discovered_links);
        } else {
            effective_html = try self.allocator.dupe(u8, raw_html);
        }
        defer self.allocator.free(effective_html);

        var parsed = try self.parser.parse(effective_html);
        errdefer parsed.deinit(self.allocator);

        const decl_canon: ?[]const u8 = if (parsed.canonical_link.len > 0) parsed.canonical_link else null;
        var canon_res = try canonicalization.resolveCanonicalUrl(
            self.allocator,
            original_url,
            redirect_url,
            decl_canon,
        );
        errdefer canon_res.deinit(self.allocator);

        const assigned_id = self.next_doc_id.fetchAdd(1, .monotonic);
        const dedup_res = try self.dedup.checkAndRegister(
            assigned_id,
            canon_res.canonical_key_hash,
            parsed.main_text,
        );

        const now_ms = time_util.nowMillis();
        const pub_ms = if (parsed.published_timestamp_ms > 0) parsed.published_timestamp_ms else now_ms;

        self.allocator.free(parsed.canonical_link);

        return .{
            .doc_id = dedup_res.matched_doc_id,
            .canonical_url = canon_res.canonical_url,
            .original_url = try self.allocator.dupe(u8, original_url),
            .domain_id = canon_res.domain_id,
            .canonical_key_hash = canon_res.canonical_key_hash,
            .content_hash = dedup_res.content_hash,
            .simhash = dedup_res.simhash,
            .title = parsed.title,
            .description = parsed.description,
            .body_text = parsed.main_text,
            .language = parsed.language,
            .fetched_at_ms = now_ms,
            .published_at_ms = pub_ms,
            .spans = parsed.spans,
            .outbound_links = parsed.links,
            .dedup_decision = dedup_res.decision,
        };
    }
};
