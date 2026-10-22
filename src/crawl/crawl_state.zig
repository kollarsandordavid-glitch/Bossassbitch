const std = @import("std");

pub const FetchState = enum(u8) {
    discovered = 0,
    scheduled = 1,
    leased = 2,
    completed = 3,
    retry_wait = 4,
    redirected = 5,
    denied = 6,
    expired = 7,
};

pub const FrontierUrlRecord = struct {
    canonical_hash: u64,
    canonical_url: []u8,
    discovery_url: []u8,
    domain_id: u64,
    fetch_state: FetchState,
    discovered_at_ms: u64,
    previous_fetch_at_ms: u64,
    next_fetch_at_ms: u64,
    lease_expires_at_ms: u64,
    content_fingerprint: u64,
    http_status: u16,
    redirect_target: []u8,
    retry_count: u16,
    priority: u16,
    provenance_depth: u16,

    pub fn deinit(self: *FrontierUrlRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_url);
        allocator.free(self.discovery_url);
        allocator.free(self.redirect_target);
    }

    pub fn canTransition(from: FetchState, to: FetchState) bool {
        return switch (from) {
            .discovered => to == .scheduled or to == .leased or to == .completed or to == .expired,
            .scheduled => to == .leased or to == .completed or to == .expired,
            .leased => to == .completed or to == .retry_wait or to == .redirected or to == .denied or to == .expired,
            .completed => to == .scheduled or to == .leased or to == .completed,
            .retry_wait => to == .scheduled or to == .leased or to == .completed or to == .expired,
            .redirected => to == .scheduled or to == .completed,
            .denied => to == .scheduled or to == .expired,
            .expired => to == .scheduled or to == .completed,
        };
    }
};
