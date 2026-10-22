const std = @import("std");

pub const Tensor2D = struct {
    allocator: std.mem.Allocator,
    rows: usize,
    cols: usize,
    data: []f32,

    pub fn initZeros(allocator: std.mem.Allocator, rows: usize, cols: usize) !Tensor2D {
        const count = rows * cols;
        const data = try allocator.alloc(f32, count);
        @memset(data, 0.0);
        return .{
            .allocator = allocator,
            .rows = rows,
            .cols = cols,
            .data = data,
        };
    }

    pub fn initDeterministicWeights(allocator: std.mem.Allocator, rows: usize, cols: usize, seed: u64) !Tensor2D {
        const count = rows * cols;
        const data = try allocator.alloc(f32, count);
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(@max(1, cols))));
        for (data) |*v| {
            v.* = (rand.float(f32) * 2.0 - 1.0) * scale;
        }
        return .{
            .allocator = allocator,
            .rows = rows,
            .cols = cols,
            .data = data,
        };
    }

    pub fn deinit(self: *Tensor2D) void {
        self.allocator.free(self.data);
    }

    pub inline fn get(self: Tensor2D, r: usize, c: usize) f32 {
        return self.data[r * self.cols + c];
    }

    pub inline fn set(self: *Tensor2D, r: usize, c: usize, val: f32) void {
        self.data[r * self.cols + c] = val;
    }

    pub inline fn rowSlice(self: Tensor2D, r: usize) []f32 {
        const start = r * self.cols;
        return self.data[start .. start + self.cols];
    }
};
