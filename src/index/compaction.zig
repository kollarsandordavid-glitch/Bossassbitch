const std = @import("std");
const candidate_scanner = @import("../scoring/candidate_scanner.zig");
const deletion_manager = @import("deletion_manager.zig");

pub const CompactionOutcome = struct {
    input_records: usize,
    retained_records: usize,
    purged_tombstones: usize,
    deduplicated_replacements: usize,
};

pub fn compactSegmentRecords(
    allocator: std.mem.Allocator,
    records: []const candidate_scanner.AlignedCandidateScanRecord,
    deletions: *deletion_manager.DeletionManager,
) !struct { compacted: []candidate_scanner.AlignedCandidateScanRecord, stats: CompactionOutcome } {
    var latest_index_by_doc = std.AutoHashMap(u64, usize).init(allocator);
    defer latest_index_by_doc.deinit();

    var purged: usize = 0;
    var replaced: usize = 0;

    for (records, 0..) |rec, idx| {
        if ((rec.flags & 1) != 0 or deletions.isDeleted(rec.doc_id)) {
            purged += 1;
            continue;
        }
        const gop = try latest_index_by_doc.getOrPut(rec.doc_id);
        if (gop.found_existing) {
            replaced += 1;
        }
        gop.value_ptr.* = idx;
    }

    var out = std.ArrayList(candidate_scanner.AlignedCandidateScanRecord).init(allocator);
    errdefer out.deinit();

    for (records, 0..) |rec, idx| {
        if (latest_index_by_doc.get(rec.doc_id)) |keep_idx| {
            if (keep_idx == idx) {
                try out.append(rec);
            }
        }
    }

    const slice = try out.toOwnedSlice();
    return .{
        .compacted = slice,
        .stats = .{
            .input_records = records.len,
            .retained_records = slice.len,
            .purged_tombstones = purged,
            .deduplicated_replacements = replaced,
        },
    };
}
