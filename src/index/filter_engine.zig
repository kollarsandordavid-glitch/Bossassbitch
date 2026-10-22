const std = @import("std");
const metadata_index = @import("metadata_index.zig");

pub const CompoundFilterCriteria = struct {
    min_published_at_ms: u64 = 0,
    max_published_at_ms: u64 = 0,
    min_quality_permille: u16 = 0,
    allowed_domain_hashes: []const u32 = &.{},
    allowed_language_hashes: []const u32 = &.{},
    allowed_doctype_hashes: []const u32 = &.{},

    pub fn isEmpty(self: CompoundFilterCriteria) bool {
        return self.min_published_at_ms == 0 and
            self.max_published_at_ms == 0 and
            self.min_quality_permille == 0 and
            self.allowed_domain_hashes.len == 0 and
            self.allowed_language_hashes.len == 0 and
            self.allowed_doctype_hashes.len == 0;
    }

    pub fn estimateSelectivityPermille(self: CompoundFilterCriteria) u16 {
        var sel: u32 = 1000;
        if (self.allowed_domain_hashes.len > 0) sel = (sel * 150) / 1000;
        if (self.allowed_language_hashes.len > 0) sel = (sel * 600) / 1000;
        if (self.allowed_doctype_hashes.len > 0) sel = (sel * 400) / 1000;
        if (self.min_published_at_ms > 0 or self.max_published_at_ms > 0) sel = (sel * 500) / 1000;
        if (self.min_quality_permille > 500) sel = (sel * 500) / 1000;
        return @intCast(@max(1, sel));
    }
};

pub const FilterEngine = struct {
    meta_idx: *metadata_index.MetadataIndex,

    pub fn init(meta_idx: *metadata_index.MetadataIndex) FilterEngine {
        return .{ .meta_idx = meta_idx };
    }

    pub fn matchesDocument(
        self: *FilterEngine,
        doc_id: u64,
        criteria: CompoundFilterCriteria,
    ) bool {
        if (criteria.isEmpty()) return true;

        if (criteria.allowed_domain_hashes.len > 0) {
            var bloom_any = false;
            for (criteria.allowed_domain_hashes) |dh| {
                if (self.meta_idx.domain_bloom.mightContainHash(dh)) {
                    bloom_any = true;
                    break;
                }
            }
            if (!bloom_any) return false;
        }

        self.meta_idx.mutex.lock();
        const attrs_opt = self.meta_idx.doc_attributes.get(doc_id);
        self.meta_idx.mutex.unlock();

        const attrs = attrs_opt orelse return false;

        if (criteria.min_quality_permille > 0 and attrs.quality_permille < criteria.min_quality_permille) {
            return false;
        }
        if (criteria.min_published_at_ms > 0 and attrs.published_at_ms < criteria.min_published_at_ms) {
            return false;
        }
        if (criteria.max_published_at_ms > 0 and attrs.published_at_ms > criteria.max_published_at_ms) {
            return false;
        }
        if (criteria.allowed_domain_hashes.len > 0) {
            var matched = false;
            for (criteria.allowed_domain_hashes) |dh| {
                if (attrs.domain_hash32 == dh) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
        if (criteria.allowed_language_hashes.len > 0) {
            var matched = false;
            for (criteria.allowed_language_hashes) |lh| {
                if (attrs.language_hash32 == lh) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
        if (criteria.allowed_doctype_hashes.len > 0) {
            var matched = false;
            for (criteria.allowed_doctype_hashes) |th| {
                if (attrs.doc_type_hash32 == th) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
        return true;
    }
};
