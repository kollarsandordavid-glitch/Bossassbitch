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

    var trainer = try core.training.training_coordinator.TrainingCoordinator.init(
        allocator,
        cfg.training,
        cfg.model,
    );
    defer trainer.deinit();

    const step_metrics = try trainer.runTrainingIterationAndCheckpoint();

    var ckpt_name_buf: [256]u8 = undefined;
    const ckpt_name = try std.fmt.bufPrint(
        &ckpt_name_buf,
        "model_v{d}_step{d}.ckpt",
        .{ trainer.active_model_version, step_metrics.global_step },
    );
    const verified = try trainer.ckpt_mgr.validateCheckpointFile(ckpt_name);

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "{{\"tool\":\"checkpoint-manager\",\"status\":\"verified\",\"checkpoint\":\"{s}\",\"model_version\":{d},\"primary_dim\":{d},\"retained_dim\":{d},\"learned_temperature\":{d:.4}}}\n",
        .{ ckpt_name, verified.model_version, verified.primary_dim, verified.retained_dim, verified.learned_temperature },
    );
}
