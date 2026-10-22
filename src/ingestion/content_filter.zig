const std = @import("std");
const document_extractor = @import("../crawl/document_extractor.zig");
const quality_features = @import("quality_features.zig");
const spam_classifier = @import("spam_classifier.zig");

pub const ContentFilterVerdict = struct {
    accepted: bool,
    quarantined: bool,
    quality_score_permille: u16,
    spam_probability_permille: u16,
    reason: []const u8,
};

pub const ContentFilter = struct {
    classifier: spam_classifier.SpamClassifier,
    min_text_bytes: u32,
    accepted_count: std.atomic.Value(u64),
    rejected_spam_count: std.atomic.Value(u64),
    quarantined_count: std.atomic.Value(u64),

    pub fn init(
        spam_threshold_permille: u16,
        min_quality_permille: u16,
        min_text_bytes: u32,
    ) ContentFilter {
        return .{
            .classifier = spam_classifier.SpamClassifier.init(spam_threshold_permille, min_quality_permille),
            .min_text_bytes = min_text_bytes,
            .accepted_count = std.atomic.Value(u64).init(0),
            .rejected_spam_count = std.atomic.Value(u64).init(0),
            .quarantined_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn evaluateDocument(self: *ContentFilter, doc: *const document_extractor.ExtractedCanonicalDocument) ContentFilterVerdict {
        if (doc.body_text.len < self.min_text_bytes) {
            _ = self.rejected_spam_count.fetchAdd(1, .monotonic);
            return .{
                .accepted = false,
                .quarantined = false,
                .quality_score_permille = 0,
                .spam_probability_permille = 950,
                .reason = "insufficient_text_length",
            };
        }

        const feat = quality_features.extractQualityFeatures(
            doc.title,
            doc.body_text,
            doc.spans,
            doc.outbound_links,
            doc.dedup_decision == .unique_content,
        );
        const cls = self.classifier.classify(feat);

        if (cls.is_honeypot_suspect) {
            _ = self.quarantined_count.fetchAdd(1, .monotonic);
            return .{
                .accepted = false,
                .quarantined = true,
                .quality_score_permille = cls.quality_score_permille,
                .spam_probability_permille = cls.spam_probability_permille,
                .reason = "quarantined_honeypot_anomaly",
            };
        }

        if (cls.is_spam) {
            _ = self.rejected_spam_count.fetchAdd(1, .monotonic);
            return .{
                .accepted = false,
                .quarantined = false,
                .quality_score_permille = cls.quality_score_permille,
                .spam_probability_permille = cls.spam_probability_permille,
                .reason = "filtered_low_quality_or_spam",
            };
        }

        _ = self.accepted_count.fetchAdd(1, .monotonic);
        return .{
            .accepted = true,
            .quarantined = false,
            .quality_score_permille = cls.quality_score_permille,
            .spam_probability_permille = cls.spam_probability_permille,
            .reason = "accepted",
        };
    }
};
