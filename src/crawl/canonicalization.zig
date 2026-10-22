const std = @import("std");
const url_norm = @import("url_normalization.zig");
const hashing = @import("../util/hashing.zig");

pub const CanonicalResolution = struct {
    canonical_url: []u8,
    canonical_key_hash: u64,
    domain_id: u64,
    used_declared_canonical: bool,

    pub fn deinit(self: *CanonicalResolution, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_url);
    }
};

pub fn resolveCanonicalUrl(
    allocator: std.mem.Allocator,
    fetched_url: []const u8,
    redirect_final_url: ?[]const u8,
    declared_canonical_link: ?[]const u8,
) !CanonicalResolution {
    const base_url = if (redirect_final_url) |redir|
        if (redir.len > 0) redir else fetched_url
    else
        fetched_url;

    const normalized_base = try url_norm.normalizeUrl(allocator, base_url);
    errdefer allocator.free(normalized_base);
    const base_domain = url_norm.extractDomainHash(normalized_base);

    if (declared_canonical_link) |decl| {
        if (decl.len > 0) {
            if (url_norm.normalizeUrl(allocator, decl)) |norm_decl| {
                const decl_domain = url_norm.extractDomainHash(norm_decl);
                if (decl_domain == base_domain) {
                    allocator.free(normalized_base);
                    return .{
                        .canonical_url = norm_decl,
                        .canonical_key_hash = hashing.wyhash64(norm_decl, 0x71e2d3c4b5a69788),
                        .domain_id = decl_domain,
                        .used_declared_canonical = true,
                    };
                } else {
                    allocator.free(norm_decl);
                }
            } else |_| {}
        }
    }

    return .{
        .canonical_url = normalized_base,
        .canonical_key_hash = hashing.wyhash64(normalized_base, 0x71e2d3c4b5a69788),
        .domain_id = base_domain,
        .used_declared_canonical = false,
    };
}
