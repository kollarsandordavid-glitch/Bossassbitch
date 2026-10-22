const std = @import("std");
const dom_executor = @import("dom_executor.zig");
const time_util = @import("../util/time.zig");

pub const BrowserRenderResult = struct {
    rendered_html: []u8,
    discovered_links: [][]u8,
    used_external_browser: bool,
    render_duration_ms: u64,

    pub fn deinit(self: *BrowserRenderResult, allocator: std.mem.Allocator) void {
        allocator.free(self.rendered_html);
        for (self.discovered_links) |l| allocator.free(l);
        allocator.free(self.discovered_links);
    }
};

pub const BrowserRuntimePool = struct {
    allocator: std.mem.Allocator,
    pool_size: u32,
    render_deadline_ms: u64,
    max_content_bytes: usize,
    active_renders: std.atomic.Value(u32),
    dom_engine: dom_executor.DomExecutor,

    pub fn init(
        allocator: std.mem.Allocator,
        pool_size: u32,
        render_deadline_ms: u64,
        max_content_bytes: usize,
    ) BrowserRuntimePool {
        return .{
            .allocator = allocator,
            .pool_size = @max(1, pool_size),
            .render_deadline_ms = render_deadline_ms,
            .max_content_bytes = max_content_bytes,
            .active_renders = std.atomic.Value(u32).init(0),
            .dom_engine = dom_executor.DomExecutor.init(allocator, max_content_bytes),
        };
    }

    pub fn requiresSpaRendering(raw_html: []const u8) bool {
        if (std.ascii.indexOfIgnoreCase(raw_html, "id=\"__NEXT_DATA__\"") != null) return true;
        if (std.ascii.indexOfIgnoreCase(raw_html, "id=\"root\"") != null) return true;
        if (std.ascii.indexOfIgnoreCase(raw_html, "id=\"app\"") != null) return true;
        if (std.ascii.indexOfIgnoreCase(raw_html, "window.__INITIAL_STATE__") != null) return true;
        if (std.ascii.indexOfIgnoreCase(raw_html, "data-reactroot") != null) return true;
        if (std.ascii.indexOfIgnoreCase(raw_html, "ng-version=") != null) return true;
        return false;
    }

    pub fn renderPage(self: *BrowserRuntimePool, url: []const u8, raw_html: []const u8) !BrowserRenderResult {
        _ = url;
        const sw = time_util.Stopwatch.start();
        const current = self.active_renders.fetchAdd(1, .acq_rel);
        defer _ = self.active_renders.fetchSub(1, .acq_rel);

        if (current >= self.pool_size or sw.elapsedMillis() >= self.render_deadline_ms) {
            return .{
                .rendered_html = try self.allocator.dupe(u8, raw_html),
                .discovered_links = try self.allocator.alloc([]u8, 0),
                .used_external_browser = false,
                .render_duration_ms = sw.elapsedMillis(),
            };
        }

        const dom_out = try self.dom_engine.executeDomScriptsAndState(raw_html);
        return .{
            .rendered_html = dom_out.augmented_html,
            .discovered_links = dom_out.discovered_spa_routes,
            .used_external_browser = false,
            .render_duration_ms = sw.elapsedMillis(),
        };
    }
};
