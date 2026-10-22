const std = @import("std");

pub const DeletionManager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    deleted_doc_ids: std.AutoHashMap(u64, u64),
    tombstone_count: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator) DeletionManager {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .deleted_doc_ids = std.AutoHashMap(u64, u64).init(allocator),
            .tombstone_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *DeletionManager) void {
        self.deleted_doc_ids.deinit();
    }

    pub fn markDeleted(self: *DeletionManager, doc_id: u64, generation_id: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = try self.deleted_doc_ids.getOrPut(doc_id);
        if (!gop.found_existing) {
            _ = self.tombstone_count.fetchAdd(1, .monotonic);
        }
        gop.value_ptr.* = generation_id;
    }

    pub fn isDeleted(self: *DeletionManager, doc_id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.deleted_doc_ids.contains(doc_id);
    }

    pub fn clearPurgedTombstones(self: *DeletionManager, up_to_generation: u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var to_remove = std.ArrayList(u64).init(self.allocator);
        defer to_remove.deinit();

        var it = self.deleted_doc_ids.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* <= up_to_generation) {
                to_remove.append(entry.key_ptr.*) catch break;
            }
        }
        for (to_remove.items) |k| {
            _ = self.deleted_doc_ids.remove(k);
        }
        const removed_count = to_remove.items.len;
        if (removed_count > 0) {
            _ = self.tombstone_count.fetchSub(@intCast(removed_count), .monotonic);
        }
        return removed_count;
    }
};
