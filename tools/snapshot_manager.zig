const std = @import("std");
const core = @import("engine_core");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_dir: []const u8 = "./settings";
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--config-dir=")) {
            config_dir = arg["--config-dir=".len..];
        }
    }

    var cfg = try core.runtime.configuration.SystemConfiguration.loadFromDirectory(allocator, config_dir);
    defer cfg.deinit();

    var vec_idx = try core.index.vector_index.DistributedVectorIndex.init(
        allocator,
        cfg.vector_index,
        cfg.model.model_version,
    );
    defer vec_idx.deinit();

    const boundary = try vec_idx.refreshAndPublishGeneration(cfg.model.model_version);
    const verified_hdr = try vec_idx.snapshot_mgr.loadSnapshotHeader(boundary.generation_id);

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "{{\"tool\":\"snapshot-manager\",\"status\":\"snapshot_created\",\"generation_id\":{d},\"commit_sequence\":{d},\"model_version\":{d}}}\n",
        .{ verified_hdr.generation_id, boundary.commit_sequence, verified_hdr.model_version },
    );
}
