const std = @import("std");
const quality_features = @import("quality_features.zig");

pub const ClassificationOutcome = struct {
    quality_score_permille: u16,
    spam_probability_permille: u16,
    is_spam: bool,
    is_honeypot_suspect: bool,
};

pub const SpamClassifier = struct {
    spam_threshold_permille: u16,
    min_quality_permille: u16,

    pub fn init(spam_threshold_permille: u16, min_quality_permille: u16) SpamClassifier {
        return .{
            .spam_threshold_permille = spam_threshold_permille,
            .min_quality_permille = min_quality_permille,
        };
    }

    pub fn classify(self: SpamClassifier, feat: quality_features.QualityFeatureVector) ClassificationOutcome {
        var logit: f32 = -1.2;

        if (feat.link_to_text_ratio_permille > 650) {
            logit += 1.8;
        }
        if (feat.unique_token_ratio_permille < 200) {
            logit += 1.6;
        }
        if (feat.source_originality_permille < 300) {
            logit += 0.9;
        }
        if (feat.structural_coherence_permille > 600) {
            logit -= 1.1;
        }
        if (feat.character_entropy_milli >= 3500 and feat.character_entropy_milli <= 5400) {
            logit -= 0.6;
        }
        if (feat.perplexity_burstiness_permille > 480 and feat.source_originality_permille >= 700 and feat.structural_coherence_permille >= 600) {
            logit -= 0.4;
        }

        const prob = 1.0 / (1.0 + @exp(-logit));
        const spam_permille: u16 = @intFromFloat(std.math.clamp(prob * 1000.0, 0.0, 1000.0));

        const base_quality: u32 = (@as(u32, feat.structural_coherence_permille) * 35 +
            @as(u32, feat.source_originality_permille) * 35 +
            @as(u32, feat.unique_token_ratio_permille) * 30) / 100;
        const penalty: u32 = @as(u32, spam_permille) / 2;
        const final_quality: u16 = @intCast(std.math.clamp(base_quality -| penalty, 0, 1000));

        const honeypot = (feat.link_to_text_ratio_permille > 880 and feat.unique_token_ratio_permille < 120) or
            (feat.character_entropy_milli > 7200);

        const is_spam = (spam_permille >= self.spam_threshold_permille) or
            (final_quality < self.min_quality_permille) or
            honeypot;

        return .{
            .quality_score_permille = final_quality,
            .spam_probability_permille = spam_permille,
            .is_spam = is_spam,
            .is_honeypot_suspect = honeypot,
        };
    }
};
