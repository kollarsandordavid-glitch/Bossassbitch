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

    try cfg.ensureStorageDirectories();
    const topo = core.util.platform.detectTopology();

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "{{\"deployment\":\"ready\",\"node_id\":\"{s}\",\"simd\":\"{s}\",\"centroids\":{d},\"primary_dim\":{d},\"retained_dim\":{d},\"packed_bytes\":{d}}}\n",
        .{
            cfg.runtime.node_id,
            @tagName(topo.preferred_simd),
            cfg.vector_index.semantic_centroids,
            cfg.model.primary_embedding_dim,
            cfg.model.matryoshka_retained_dim,
            cfg.scoring.packed_bytes,
        },
    );
}
