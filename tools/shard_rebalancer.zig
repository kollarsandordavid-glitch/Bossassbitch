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

    var total_records: usize = 0;
    var max_shard_records: usize = 0;
    for (vec_idx.shards.shards) |*s| {
        const c = s.recordCount();
        total_records += c;
        if (c > max_shard_records) max_shard_records = c;
    }

    const purged = try vec_idx.shards.compactAllShards(
        &vec_idx.segment_store,
        &vec_idx.deletions,
        vec_idx.consistency_coord.active_generation.load(.acquire),
    );

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "{{\"tool\":\"shard-rebalancer\",\"status\":\"completed\",\"shard_count\":{d},\"total_records\":{d},\"max_shard_records\":{d},\"purged_tombstones\":{d}}}\n",
        .{ vec_idx.shards.shards.len, total_records, max_shard_records, purged },
    );
}
