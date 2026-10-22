const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    const core_module = b.addModule("engine_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const modal_protocol_module = b.addModule("modal_protocol", .{
        .root_source_file = b.path("modal/workload_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    modal_protocol_module.addImport("engine_core", core_module);

    const modal_artifacts_module = b.addModule("modal_artifacts", .{
        .root_source_file = b.path("modal/model_artifacts.zig"),
        .target = target,
        .optimize = optimize,
    });
    modal_artifacts_module.addImport("engine_core", core_module);
    modal_artifacts_module.addImport("modal_protocol", modal_protocol_module);

    core_module.addImport("modal_protocol", modal_protocol_module);
    core_module.addImport("modal_artifacts", modal_artifacts_module);

    const main_exe = b.addExecutable(.{
        .name = "search-engine-node",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_exe.root_module.addImport("engine_core", core_module);
    main_exe.root_module.addImport("modal_protocol", modal_protocol_module);
    main_exe.root_module.addImport("modal_artifacts", modal_artifacts_module);
    b.installArtifact(main_exe);

    const role_binaries = [_]struct { name: []const u8, role: []const u8 }{
        .{ .name = "search-coordinator", .role = "search" },
        .{ .name = "crawler-worker", .role = "crawler" },
        .{ .name = "ingestion-processor", .role = "ingestion" },
        .{ .name = "index-writer", .role = "indexer" },
        .{ .name = "training-coordinator", .role = "training" },
        .{ .name = "embedding-client", .role = "embedding" },
        .{ .name = "research-worker", .role = "research" },
    };

    for (role_binaries) |rb| {
        const exe = b.addExecutable(.{
            .name = rb.name,
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        const opts = b.addOptions();
        opts.addOption([]const u8, "default_role", rb.role);
        exe.root_module.addOptions("build_options", opts);
        exe.root_module.addImport("engine_core", core_module);
        exe.root_module.addImport("modal_protocol", modal_protocol_module);
        exe.root_module.addImport("modal_artifacts", modal_artifacts_module);
        b.installArtifact(exe);
    }

    const default_opts = b.addOptions();
    default_opts.addOption([]const u8, "default_role", "all");
    main_exe.root_module.addOptions("build_options", default_opts);

    const tool_targets = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "index-builder", .path = "tools/index_builder.zig" },
        .{ .name = "corpus-ingestor", .path = "tools/corpus_ingestor.zig" },
        .{ .name = "checkpoint-manager", .path = "tools/checkpoint_manager.zig" },
        .{ .name = "shard-rebalancer", .path = "tools/shard_rebalancer.zig" },
        .{ .name = "snapshot-manager", .path = "tools/snapshot_manager.zig" },
        .{ .name = "cluster-launcher", .path = "tools/cluster_launcher.zig" },
        .{ .name = "deploy-launch", .path = "deploy/launch.zig" },
    };

    for (tool_targets) |tt| {
        const tool_exe = b.addExecutable(.{
            .name = tt.name,
            .root_source_file = b.path(tt.path),
            .target = target,
            .optimize = optimize,
        });
        tool_exe.root_module.addImport("engine_core", core_module);
        tool_exe.root_module.addImport("modal_protocol", modal_protocol_module);
        tool_exe.root_module.addImport("modal_artifacts", modal_artifacts_module);
        b.installArtifact(tool_exe);
    }
}
