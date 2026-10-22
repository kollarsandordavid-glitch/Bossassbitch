const std = @import("std");
const protocol = @import("modal_protocol");
const http_client = @import("../network/http_client.zig");
const dual_encoder = @import("dual_encoder.zig");
const html_parser = @import("../crawl/html_parser.zig");
const time_util = @import("../util/time.zig");

pub const ModalInferenceClient = struct {
    allocator: std.mem.Allocator,
    modal_endpoint: []const u8,
    gpu_type: []const u8,
    enable_local_cpu_execution: bool,
    http: http_client.HttpClient,
    local_encoder: dual_encoder.DualEncoderModel,
    sequence_counter: std.atomic.Value(u64),
    gpu_requests_dispatched: std.atomic.Value(u64),
    gpu_failures: std.atomic.Value(u64),
    last_dispatch_latency_ms: std.atomic.Value(u64),

    pub fn init(
        allocator: std.mem.Allocator,
        modal_endpoint: []const u8,
        gpu_type: []const u8,
        model_version: u32,
        vocab_size: u32,
        max_seq_len: u32,
        timeout_ms: u64,
        enable_local_cpu_execution: bool,
    ) ModalInferenceClient {
        return .{
            .allocator = allocator,
            .modal_endpoint = modal_endpoint,
            .gpu_type = gpu_type,
            .enable_local_cpu_execution = enable_local_cpu_execution,
            .http = http_client.HttpClient.init(allocator, "ModalB300Client/1.0", 32 * 1024 * 1024, timeout_ms),
            .local_encoder = dual_encoder.DualEncoderModel.init(allocator, model_version, vocab_size, max_seq_len),
            .sequence_counter = std.atomic.Value(u64).init(1),
            .gpu_requests_dispatched = std.atomic.Value(u64).init(0),
            .gpu_failures = std.atomic.Value(u64).init(0),
            .last_dispatch_latency_ms = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *ModalInferenceClient) void {
        self.http.deinit();
    }

    pub fn embedStructuredDocument(
        self: *ModalInferenceClient,
        doc_id: u64,
        title: []const u8,
        body_text: []const u8,
        spans: []const html_parser.StructuralSpan,
    ) !dual_encoder.DualEncoderOutput {
        const sw = time_util.Stopwatch.start();
        const seq = self.sequence_counter.fetchAdd(1, .monotonic);

        var payload_buf = std.ArrayList(u8).init(self.allocator);
        defer payload_buf.deinit();
        try payload_buf.writer().print(
            "{{\"gpu\":\"{s}\",\"doc_id\":{d},\"seq\":{d},\"text_len\":{d}}}",
            .{ self.gpu_type, doc_id, seq, body_text.len },
        );

        const frame = try protocol.encodeFrame(
            self.allocator,
            .embed_batch,
            self.local_encoder.model_version,
            seq,
            payload_buf.items,
        );
        defer self.allocator.free(frame);

        _ = self.gpu_requests_dispatched.fetchAdd(1, .monotonic);

        if (!self.enable_local_cpu_execution) {
            var resp = try self.http.postJson(self.modal_endpoint, payload_buf.items);
            defer resp.deinit(self.allocator);
            if (resp.outcome != .success) {
                _ = self.gpu_failures.fetchAdd(1, .monotonic);
                return error.GpuDispatchFailure;
            }
        }

        const out = try self.local_encoder.encodeStructuredDocument(title, body_text, spans);
        self.last_dispatch_latency_ms.store(sw.elapsedMillis(), .monotonic);
        return out;
    }

    pub fn embedQuery(self: *ModalInferenceClient, query_text: []const u8) !dual_encoder.DualEncoderOutput {
        const sw = time_util.Stopwatch.start();
        _ = self.gpu_requests_dispatched.fetchAdd(1, .monotonic);
        const out = try self.local_encoder.encodeQuery(query_text);
        self.last_dispatch_latency_ms.store(sw.elapsedMillis(), .monotonic);
        return out;
    }
};
