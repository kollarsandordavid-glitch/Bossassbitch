const std = @import("std");

pub const VerificationStatus = enum(u8) {
    direct_support = 0,
    partial_support = 1,
    conflicting_evidence = 2,
    insufficient_evidence = 3,

    pub fn toString(self: VerificationStatus) []const u8 {
        return switch (self) {
            .direct_support => "direct_support",
            .partial_support => "partial_support",
            .conflicting_evidence => "conflicting_evidence",
            .insufficient_evidence => "insufficient_evidence",
        };
    }
};

pub const VerifiedClaimRecord = struct {
    claim_text: []u8,
    doc_id: u64,
    source_url: []u8,
    evidence_span: []u8,
    confidence_permille: u16,
    contradiction_detected: bool,
    status: VerificationStatus,

    pub fn deinit(self: *VerifiedClaimRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.claim_text);
        allocator.free(self.source_url);
        allocator.free(self.evidence_span);
    }
};

pub const CitationVerifier = struct {
    pub fn init() CitationVerifier {
        return .{};
    }

    pub fn verifyClaimAgainstDocument(
        self: CitationVerifier,
        allocator: std.mem.Allocator,
        claim_text: []const u8,
        doc_id: u64,
        source_url: []const u8,
        doc_body: []const u8,
    ) !VerifiedClaimRecord {
        _ = self;
        var best_sentence: []const u8 = "";
        var best_overlap: u32 = 0;
        var claim_terms: u32 = 0;

        var c_iter = std.mem.tokenizeAny(u8, claim_text, " \t\r\n,.;:!?()[]{}");
        while (c_iter.next()) |tok| {
            if (tok.len >= 3) claim_terms += 1;
        }

        var sent_iter = std.mem.splitAny(u8, doc_body, ".\n");
        while (sent_iter.next()) |raw_sent| {
            const sent = std.mem.trim(u8, raw_sent, " \t\r\n");
            if (sent.len < 8) continue;

            var hits: u32 = 0;
            var q_iter = std.mem.tokenizeAny(u8, claim_text, " \t\r\n,.;:!?()[]{}");
            while (q_iter.next()) |q_tok| {
                if (q_tok.len < 3) continue;
                if (std.ascii.indexOfIgnoreCase(sent, q_tok) != null) {
                    hits += 1;
                }
            }
            if (hits > best_overlap) {
                best_overlap = hits;
                best_sentence = sent;
            }
        }

        const claim_has_neg = hasNegationMarker(claim_text);
        const sent_has_neg = hasNegationMarker(best_sentence);
        const contradiction = (best_overlap >= 2) and (claim_has_neg != sent_has_neg);

        const coverage_permille: u16 = if (claim_terms == 0)
            0
        else
            @intCast(@min(1000, (best_overlap * 1000) / claim_terms));

        var status: VerificationStatus = .insufficient_evidence;
        var confidence: u16 = coverage_permille;

        if (contradiction) {
            status = .conflicting_evidence;
            confidence = @max(650, coverage_permille);
        } else if (coverage_permille >= 700 and best_sentence.len > 0) {
            status = .direct_support;
            confidence = @min(980, coverage_permille + 120);
        } else if (coverage_permille >= 350 and best_sentence.len > 0) {
            status = .partial_support;
            confidence = coverage_permille;
        } else {
            status = .insufficient_evidence;
            confidence = @min(300, coverage_permille);
        }

        return .{
            .claim_text = try allocator.dupe(u8, claim_text),
            .doc_id = doc_id,
            .source_url = try allocator.dupe(u8, source_url),
            .evidence_span = try allocator.dupe(u8, best_sentence),
            .confidence_permille = confidence,
            .contradiction_detected = contradiction,
            .status = status,
        };
    }
};

fn hasNegationMarker(text: []const u8) bool {
    if (std.ascii.indexOfIgnoreCase(text, " not ") != null) return true;
    if (std.ascii.indexOfIgnoreCase(text, " never ") != null) return true;
    if (std.ascii.indexOfIgnoreCase(text, " false ") != null) return true;
    if (std.ascii.indexOfIgnoreCase(text, " impossible ") != null) return true;
    return false;
}
