const std = @import("std");
const builtin = @import("builtin");

pub const SimdBackend = enum {
    x86_avx512,
    x86_avx2,
    arm_sve,
    arm_neon,
    scalar,
};

pub const HardwareTopology = struct {
    arch: std.Target.Cpu.Arch,
    logical_cores: u32,
    numa_nodes: u32,
    l1_cache_bytes: u32,
    l2_cache_bytes: u32,
    l3_cache_bytes: u32,
    cache_line_bytes: u32,
    has_avx2: bool,
    has_avx512f: bool,
    has_avx512_vpopcntdq: bool,
    has_neon: bool,
    has_sve: bool,
    preferred_simd: SimdBackend,
};

pub fn detectTopology() HardwareTopology {
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const arch = builtin.cpu.arch;
    var has_avx2 = false;
    var has_avx512f = false;
    var has_avx512_vpopcntdq = false;
    var has_neon = false;
    var has_sve = false;

    if (arch == .x86_64) {
        has_avx2 = std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
        has_avx512f = std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f);
        has_avx512_vpopcntdq = std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vpopcntdq);
    } else if (arch == .aarch64) {
        has_neon = std.Target.aarch64.featureSetHas(builtin.cpu.features, .neon);
        has_sve = std.Target.aarch64.featureSetHas(builtin.cpu.features, .sve);
    }

    const preferred: SimdBackend = if (has_avx512f)
        .x86_avx512
    else if (has_avx2)
        .x86_avx2
    else if (has_sve)
        .arm_sve
    else if (has_neon)
        .arm_neon
    else
        .scalar;

    const numa_count: u32 = if (cpu_count >= 32) 2 else 1;

    return .{
        .arch = arch,
        .logical_cores = @intCast(cpu_count),
        .numa_nodes = numa_count,
        .l1_cache_bytes = 32 * 1024,
        .l2_cache_bytes = 1024 * 1024,
        .l3_cache_bytes = 32 * 1024 * 1024,
        .cache_line_bytes = 64,
        .has_avx2 = has_avx2,
        .has_avx512f = has_avx512f,
        .has_avx512_vpopcntdq = has_avx512_vpopcntdq,
        .has_neon = has_neon,
        .has_sve = has_sve,
        .preferred_simd = preferred,
    };
}

pub fn selectNumaNodeForShard(shard_id: u32, topology: HardwareTopology) u32 {
    if (topology.numa_nodes <= 1) return 0;
    return shard_id % topology.numa_nodes;
}
