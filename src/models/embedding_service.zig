const std = @import("std");
const configuration = @import("../runtime/configuration.zig");
const model_registry = @import("model_registry.zig");
const checkpoint = @import("checkpoint.zig");
const inference_client = @import("inference_client.zig");
const dual_encoder = @import("dual_encoder.zig");
const html_parser = @import("../crawl/html_parser.zig");

pub const EmbeddingService = struct {
    allocator: std.mem.Allocator,
    registry: model_registry.ModelRegistry,
    ckpt_mgr: checkpoint.CheckpointManager,
    client: inference_client.ModalInferenceClient,
    documents_embedded: std.atomic.Value(u64),
    queries_embedded: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, cfg: configuration.ModelConfig) !*EmbeddingService {
        const self = try allocator.create(EmbeddingService);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.registry = model_registry.ModelRegistry.init(allocator, cfg.model_version);
        errdefer self.registry.deinit();

        self.ckpt_mgr = try checkpoint.CheckpointManager.init(allocator, cfg.checkpoint_dir);
        errdefer self.ckpt_mgr.deinit();

        self.client = inference_client.ModalInferenceClient.init(
            allocator,
            cfg.modal_endpoint,
            cfg.modal_gpu_type,
            cfg.model_version,
            cfg.vocab_size,
            cfg.max_sequence_length,
            cfg.modal_timeout_ms,
            cfg.enable_local_cpu_execution,
        );
        self.documents_embedded = std.atomic.Value(u64).init(0);
        self.queries_embedded = std.atomic.Value(u64).init(0);
        return self;
    }

    pub fn deinit(self: *EmbeddingService) void {
        self.client.deinit();
        self.ckpt_mgr.deinit();
        self.registry.deinit();
        self.allocator.destroy(self);
    }

    pub fn embedDocument(
        self: *EmbeddingService,
        doc_id: u64,
        title: []const u8,
        body_text: []const u8,
        spans: []const html_parser.StructuralSpan,
    ) !dual_encoder.DualEncoderOutput {
        const out = try self.client.embedStructuredDocument(doc_id, title, body_text, spans);
        _ = self.documents_embedded.fetchAdd(1, .monotonic);
        return out;
    }

    pub fn embedQueryText(self: *EmbeddingService, query_text: []const u8) !dual_encoder.DualEncoderOutput {
        const out = try self.client.embedQuery(query_text);
        _ = self.queries_embedded.fetchAdd(1, .monotonic);
        return out;
    }

    pub fn activeModelVersion(self: *EmbeddingService) u32 {
        return self.registry.currentDescriptor().model_version;
    }
};
