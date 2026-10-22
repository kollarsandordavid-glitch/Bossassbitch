const std = @import("std");
const anomaly_detection = @import("anomaly_detection.zig");

pub const CrawlerAnomalyMonitor = struct {
    content_length_detector: anomaly_detection.RollingAnomalyDetector,
    missing_title_count: std.atomic.Value(u64),
    template_shift_alerts: std.atomic.Value(u64),
    honeypot_quarantine_alerts: std.atomic.Value(u64),

    pub fn init(zscore_threshold_milli: u32) CrawlerAnomalyMonitor {
        return .{
            .content_length_detector = anomaly_detection.RollingAnomalyDetector.init(zscore_threshold_milli),
            .missing_title_count = std.atomic.Value(u64).init(0),
            .template_shift_alerts = std.atomic.Value(u64).init(0),
            .honeypot_quarantine_alerts = std.atomic.Value(u64).init(0),
        };
    }

    pub fn observeExtraction(
        self: *CrawlerAnomalyMonitor,
        body_len: usize,
        has_title: bool,
        quarantined_honeypot: bool,
    ) bool {
        if (!has_title) {
            _ = self.missing_title_count.fetchAdd(1, .monotonic);
        }
        if (quarantined_honeypot) {
            _ = self.honeypot_quarantine_alerts.fetchAdd(1, .monotonic);
        }
        const length_anomaly = self.content_length_detector.observeAndCheckAnomaly(@floatFromInt(body_len));
        if (length_anomaly) {
            _ = self.template_shift_alerts.fetchAdd(1, .monotonic);
        }
        return length_anomaly or quarantined_honeypot;
    }
};
