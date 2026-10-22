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

    const topo = core.util.platform.detectTopology();
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "{{\"tool\":\"cluster-launcher\",\"status\":\"validated\",\"cluster_name\":\"{s}\",\"node_id\":\"{s}\",\"logical_cores\":{d},\"numa_nodes\":{d},\"preferred_simd\":\"{s}\",\"rpc_port\":{d},\"http_port\":{d}}}\n",
        .{
            cfg.runtime.cluster_name,
            cfg.runtime.node_id,
            topo.logical_cores,
            topo.numa_nodes,
            @tagName(topo.preferred_simd),
            cfg.distributed.rpc_port,
            cfg.api.port,
        },
    );
}
