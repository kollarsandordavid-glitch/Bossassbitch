const std = @import("std");
const http_client = @import("../network/http_client.zig");

pub const DistributedFetchResult = struct {
    final_url: []u8,
    status_code: u16,
    outcome: http_client.FetchOutcomeKind,
    body: []u8,
    redirect_hops: u8,
    elapsed_ms: u64,

    pub fn deinit(self: *DistributedFetchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.final_url);
        allocator.free(self.body);
    }
};

pub const CrawlerFetcher = struct {
    allocator: std.mem.Allocator,
    client: http_client.HttpClient,
    max_redirects: u8,
    pages_fetched_total: std.atomic.Value(u64),
    bytes_fetched_total: std.atomic.Value(u64),
    denied_or_challenged_total: std.atomic.Value(u64),

    pub fn init(
        allocator: std.mem.Allocator,
        user_agent: []const u8,
        max_response_bytes: usize,
        connect_timeout_ms: u64,
        max_redirects: u8,
    ) CrawlerFetcher {
        return .{
            .allocator = allocator,
            .client = http_client.HttpClient.init(allocator, user_agent, max_response_bytes, connect_timeout_ms),
            .max_redirects = max_redirects,
            .pages_fetched_total = std.atomic.Value(u64).init(0),
            .bytes_fetched_total = std.atomic.Value(u64).init(0),
            .denied_or_challenged_total = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *CrawlerFetcher) void {
        self.client.deinit();
    }

    pub fn fetchWithRedirects(self: *CrawlerFetcher, initial_url: []const u8) !DistributedFetchResult {
        var current_url = try self.allocator.dupe(u8, initial_url);
        errdefer self.allocator.free(current_url);

        var hops: u8 = 0;
        var total_elapsed: u64 = 0;

        while (true) {
            var resp = try self.client.get(current_url, null);
            defer resp.deinit(self.allocator);
            total_elapsed += resp.elapsed_ms;

            if (resp.outcome == .redirect and hops < self.max_redirects and resp.location_header.len > 0) {
                const next_url = try self.allocator.dupe(u8, resp.location_header);
                self.allocator.free(current_url);
                current_url = next_url;
                hops += 1;
                continue;
            }

            if (resp.outcome == .access_denied_or_challenge) {
                _ = self.denied_or_challenged_total.fetchAdd(1, .monotonic);
            } else if (resp.outcome == .success) {
                _ = self.pages_fetched_total.fetchAdd(1, .monotonic);
                _ = self.bytes_fetched_total.fetchAdd(resp.body.len, .monotonic);
            }

            return .{
                .final_url = current_url,
                .status_code = resp.status_code,
                .outcome = resp.outcome,
                .body = try self.allocator.dupe(u8, resp.body),
                .redirect_hops = hops,
                .elapsed_ms = total_elapsed,
            };
        }
    }
};
