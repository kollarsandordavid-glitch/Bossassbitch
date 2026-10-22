const std = @import("std");

pub const LinkEdgeRecord = struct {
    source_domain_id: u64,
    target_domain_id: u64,
    anchor_hash: u64,
    created_at_ms: u64,
    is_sponsored_or_nofollow: bool,
};

pub const GraphQualityAssessment = struct {
    manipulation_probability_permille: u16,
    reciprocal_ratio_permille: u16,
    anchor_repetition_permille: u16,
    temporal_burst_detected: bool,
    training_example_weight: f32,
};

pub const LinkGraphQualityAnalyzer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LinkGraphQualityAnalyzer {
        return .{ .allocator = allocator };
    }

    pub fn evaluateSubgraph(
        self: LinkGraphQualityAnalyzer,
        edges: []const LinkEdgeRecord,
        source_authority_permille: u16,
    ) GraphQualityAssessment {
        _ = self;
        if (edges.len == 0) {
            return .{
                .manipulation_probability_permille = 0,
                .reciprocal_ratio_permille = 0,
                .anchor_repetition_permille = 0,
                .temporal_burst_detected = false,
                .training_example_weight = 1.0,
            };
        }

        var reciprocal_count: usize = 0;
        var repeated_anchors: usize = 0;
        var sponsored_count: usize = 0;
        var burst_pairs: usize = 0;

        for (edges, 0..) |e1, i| {
            if (e1.is_sponsored_or_nofollow) sponsored_count += 1;
            var j: usize = i + 1;
            while (j < edges.len and j < i + 64) : (j += 1) {
                const e2 = edges[j];
                if (e1.source_domain_id == e2.target_domain_id and
                    e1.target_domain_id == e2.source_domain_id and
                    e1.source_domain_id != e1.target_domain_id)
                {
                    reciprocal_count += 1;
                }
                if (e1.anchor_hash == e2.anchor_hash and e1.source_domain_id != e2.source_domain_id) {
                    repeated_anchors += 1;
                }
                const dt = if (e1.created_at_ms >= e2.created_at_ms)
                    e1.created_at_ms - e2.created_at_ms
                else
                    e2.created_at_ms - e1.created_at_ms;
                if (dt < 5000 and e1.target_domain_id == e2.target_domain_id) {
                    burst_pairs += 1;
                }
            }
        }

        const total = edges.len;
        const recip_permille: u16 = @intCast(@min(1000, (reciprocal_count * 1000) / total));
        const anchor_rep_permille: u16 = @intCast(@min(1000, (repeated_anchors * 1000) / total));
        const sponsored_permille: u16 = @intCast(@min(1000, (sponsored_count * 1000) / total));
        const burst = burst_pairs * 4 >= total and total >= 8;

        var manip_score: u32 = (@as(u32, anchor_rep_permille) * 45 +
            @as(u32, sponsored_permille) * 30 +
            @as(u32, recip_permille) * 25) / 100;
        if (burst) manip_score += 250;

        if (source_authority_permille >= 750 and anchor_rep_permille < 300 and !burst) {
            manip_score = manip_score / 3;
        }

        const clamped_manip: u16 = @intCast(@min(1000, manip_score));
        const weight = std.math.clamp(
            (1.0 - @as(f32, @floatFromInt(clamped_manip)) / 1000.0) *
                (0.5 + @as(f32, @floatFromInt(source_authority_permille)) / 1000.0),
            0.05,
            1.5,
        );

        return .{
            .manipulation_probability_permille = clamped_manip,
            .reciprocal_ratio_permille = recip_permille,
            .anchor_repetition_permille = anchor_rep_permille,
            .temporal_burst_detected = burst,
            .training_example_weight = weight,
        };
    }
};
