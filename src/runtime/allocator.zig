const std = @import("std");

pub const BoundedAllocator = struct {
    backing: std.mem.Allocator,
    max_bytes: u64,
    current_bytes: std.atomic.Value(u64),
    peak_bytes: std.atomic.Value(u64),
    alloc_count: std.atomic.Value(u64),
    free_count: std.atomic.Value(u64),
    reject_count: std.atomic.Value(u64),

    pub fn init(backing: std.mem.Allocator, max_bytes: u64) BoundedAllocator {
        return .{
            .backing = backing,
            .max_bytes = max_bytes,
            .current_bytes = std.atomic.Value(u64).init(0),
            .peak_bytes = std.atomic.Value(u64).init(0),
            .alloc_count = std.atomic.Value(u64).init(0),
            .free_count = std.atomic.Value(u64).init(0),
            .reject_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn allocator(self: *BoundedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    pub fn usedBytes(self: *const BoundedAllocator) u64 {
        return self.current_bytes.load(.monotonic);
    }

    pub fn peakUsedBytes(self: *const BoundedAllocator) u64 {
        return self.peak_bytes.load(.monotonic);
    }

    fn recordPeak(self: *BoundedAllocator, updated: u64) void {
        var prev = self.peak_bytes.load(.monotonic);
        while (updated > prev) {
            if (self.peak_bytes.cmpxchgWeak(prev, updated, .monotonic, .monotonic)) |actual| {
                prev = actual;
            } else {
                break;
            }
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ctx));
        const add_bytes: u64 = @intCast(len);
        const current = self.current_bytes.load(.monotonic);
        if (current +| add_bytes > self.max_bytes) {
            _ = self.reject_count.fetchAdd(1, .monotonic);
            return null;
        }
        const ptr = self.backing.rawAlloc(len, ptr_align, ret_addr) orelse {
            _ = self.reject_count.fetchAdd(1, .monotonic);
            return null;
        };
        const updated = self.current_bytes.fetchAdd(add_bytes, .monotonic) + add_bytes;
        _ = self.alloc_count.fetchAdd(1, .monotonic);
        self.recordPeak(updated);
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            const delta: u64 = @intCast(new_len - buf.len);
            if (self.current_bytes.load(.monotonic) +| delta > self.max_bytes) {
                _ = self.reject_count.fetchAdd(1, .monotonic);
                return false;
            }
            if (self.backing.rawResize(buf, buf_align, new_len, ret_addr)) {
                const updated = self.current_bytes.fetchAdd(delta, .monotonic) + delta;
                self.recordPeak(updated);
                return true;
            }
            return false;
        } else {
            const delta: u64 = @intCast(buf.len - new_len);
            if (self.backing.rawResize(buf, buf_align, new_len, ret_addr)) {
                _ = self.current_bytes.fetchSub(delta, .monotonic);
                return true;
            }
            return false;
        }
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ctx));
        const sub_bytes: u64 = @intCast(buf.len);
        self.backing.rawFree(buf, buf_align, ret_addr);
        _ = self.current_bytes.fetchSub(sub_bytes, .monotonic);
        _ = self.free_count.fetchAdd(1, .monotonic);
    }
};
