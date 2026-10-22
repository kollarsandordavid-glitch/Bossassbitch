const std = @import("std");

pub const TlsSecurityOutcome = enum {
    plaintext_allowed,
    tls_verified,
    tls_handshake_failed,
    certificate_invalid,
};

pub const TlsContext = struct {
    allocator: std.mem.Allocator,
    ca_bundle: std.crypto.Certificate.Bundle,
    initialized: bool,

    pub fn init(allocator: std.mem.Allocator) TlsContext {
        var bundle = std.crypto.Certificate.Bundle{};
        bundle.rescan(allocator) catch {};
        return .{
            .allocator = allocator,
            .ca_bundle = bundle,
            .initialized = true,
        };
    }

    pub fn deinit(self: *TlsContext) void {
        self.ca_bundle.deinit(self.allocator);
        self.initialized = false;
    }

    pub fn validateHostname(host: []const u8) bool {
        if (host.len == 0 or host.len > 253) return false;
        for (host) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != ':') {
                return false;
            }
        }
        return true;
    }
};
