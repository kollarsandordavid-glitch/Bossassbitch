const std = @import("std");
const hashing = @import("hashing.zig");

pub const HyperLogLog = struct {
    registers: [1024]u8,

    pub fn init() HyperLogLog {
        return .{ .registers = [_]u8{0} ** 1024 };
    }

    pub fn add(self: *HyperLogLog, data: []const u8) void {
        const h = hashing.wyhash64(data, 0x517cc1b727220a95);
        self.addHash(h);
    }

    pub fn addHash(self: *HyperLogLog, h: u64) void {
        const idx: usize = @intCast(h & 1023);
        const w = h >> 10;
        const rank: u8 = if (w == 0) 55 else @intCast(@clz(w) - 10 + 1);
        if (rank > self.registers[idx]) {
            self.registers[idx] = rank;
        }
    }

    pub fn countEstimate(self: *const HyperLogLog) u64 {
        const m: f64 = 1024.0;
        const alpha: f64 = 0.7213 / (1.0 + 1.079 / m);
        var sum: f64 = 0.0;
        var zero_count: usize = 0;
        for (self.registers) |r| {
            if (r == 0) zero_count += 1;
            sum += std.math.pow(f64, 2.0, -@as(f64, @floatFromInt(r)));
        }
        var estimate = alpha * m * m / sum;
        if (estimate <= 2.5 * m and zero_count > 0) {
            estimate = m * @log(m / @as(f64, @floatFromInt(zero_count)));
        }
        return @intFromFloat(@max(0.0, estimate));
    }
};

pub const CountMinSketch = struct {
    table: [4][2048]u32,

    pub fn init() CountMinSketch {
        return .{
            .table = [_][2048]u32{[_]u32{0} ** 2048} ** 4,
        };
    }

    pub fn increment(self: *CountMinSketch, key: []const u8, delta: u32) void {
        const seeds = [4]u64{ 0x101, 0x202, 0x303, 0x404 };
        for (seeds, 0..) |seed, row| {
            const col: usize = @intCast(hashing.wyhash64(key, seed) & 2047);
            self.table[row][col] = self.table[row][col] +| delta;
        }
    }

    pub fn estimate(self: *const CountMinSketch, key: []const u8) u32 {
        const seeds = [4]u64{ 0x101, 0x202, 0x303, 0x404 };
        var min_val: u32 = std.math.maxInt(u32);
        for (seeds, 0..) |seed, row| {
            const col: usize = @intCast(hashing.wyhash64(key, seed) & 2047);
            if (self.table[row][col] < min_val) {
                min_val = self.table[row][col];
            }
        }
        return min_val;
    }
};
