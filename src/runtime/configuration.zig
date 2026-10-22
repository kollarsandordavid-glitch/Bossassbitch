const std = @import("std");
const errors = @import("errors.zig");

pub const RuntimeConfig = struct {
    schema_version: u32 = 1,
    node_id: []const u8 = "node-primary-0001",
    cluster_name: []const u8 = "neural-search-production",
    environment: []const u8 = "production",
    data_root: []const u8 = "./var/lib/neural_search",
    worker_threads: u32 = 16,
    io_threads: u32 = 8,
    background_threads: u32 = 4,
    max_heap_bytes: u64 = 68719476736,
    arena_block_bytes: u64 = 4194304,
    shutdown_grace_ms: u64 = 15000,
    heartbeat_interval_ms: u64 = 1000,
    numa_aware: bool = true,
    pin_worker_threads: bool = true,
    enable_avx512: bool = true,
    enable_avx2: bool = true,
    enable_neon: bool = true,
    enable_sve: bool = true,
};

pub const CrawlerConfig = struct {
    schema_version: u32 = 1,
    target_frontier_capacity_urls: u64 = 1400000000000,
    daily_crawl_target_pages: u64 = 5000000000,
    frontier_partitions: u32 = 64,
    frontier_storage_path: []const u8 = "./var/lib/neural_search/frontier",
    wal_storage_path: []const u8 = "./var/lib/neural_search/frontier_wal",
    bloom_bits_per_entry: u32 = 14,
    bloom_hash_count: u8 = 10,
    max_concurrent_fetches: u32 = 4096,
    max_connections_per_host: u32 = 8,
    connect_timeout_ms: u64 = 4000,
    read_timeout_ms: u64 = 10000,
    max_response_bytes: u64 = 16777216,
    max_redirects: u8 = 6,
    user_agent: []const u8 = "DistributedNeuralCrawler/1.0",
    browser_pool_size: u32 = 8,
    browser_render_deadline_ms: u64 = 8000,
    dom_max_depth: u32 = 256,
    dom_max_nodes: u32 = 131072,
    shingle_width: u32 = 5,
    simhash_hamming_threshold: u8 = 3,
    min_recrawl_interval_sec: u64 = 120,
    default_recrawl_interval_sec: u64 = 86400,
    max_recrawl_interval_sec: u64 = 2592000,
    lease_duration_ms: u64 = 30000,
};

pub const IngestionConfig = struct {
    schema_version: u32 = 1,
    stream_partitions: u32 = 32,
    wal_dir: []const u8 = "./var/lib/neural_search/ingestion_wal",
    segment_max_bytes: u64 = 268435456,
    max_in_memory_events: u32 = 65536,
    max_queue_bytes: u64 = 1073741824,
    backpressure_high_watermark_permille: u32 = 850,
    backpressure_low_watermark_permille: u32 = 600,
    batch_flush_interval_ms: u64 = 250,
    live_index_publish_interval_sec: u64 = 3600,
    priority_publish_interval_sec: u64 = 30,
    spam_probability_threshold_permille: u32 = 780,
    min_quality_score_permille: u32 = 260,
    min_text_bytes: u32 = 64,
    max_duplicate_ratio_permille: u32 = 820,
    anomaly_quarantine_threshold_permille: u32 = 900,
};

pub const ModelConfig = struct {
    schema_version: u32 = 1,
    model_family: []const u8 = "dual-encoder-matryoshka-v1",
    model_version: u32 = 1001,
    vocab_size: u32 = 65536,
    max_sequence_length: u32 = 2048,
    hidden_size: u32 = 4096,
    primary_embedding_dim: u32 = 4096,
    matryoshka_retained_dim: u32 = 256,
    binary_packed_bytes: u32 = 32,
    num_layers: u32 = 24,
    num_attention_heads: u32 = 32,
    intermediate_size: u32 = 11008,
    structural_feature_dim: u32 = 64,
    entity_category_count: u32 = 12,
    checkpoint_dir: []const u8 = "./var/lib/neural_search/checkpoints",
    modal_endpoint: []const u8 = "https://modal-gpu-dispatch.internal/v1",
    modal_gpu_type: []const u8 = "B300",
    modal_batch_size: u32 = 256,
    modal_timeout_ms: u64 = 12000,
    enable_local_cpu_execution: bool = true,
};

pub const TrainingConfig = struct {
    schema_version: u32 = 1,
    production_gpu_profile: []const u8 = "NVIDIA-B300-Modal",
    reference_curriculum_profile: []const u8 = "144x-NVIDIA-H200",
    reference_h200_gpu_count: u32 = 144,
    production_b300_gpu_count: u32 = 16,
    global_batch_size: u32 = 16384,
    micro_batch_size: u32 = 64,
    gradient_accumulation_steps: u32 = 16,
    base_learning_rate_micro: u32 = 150,
    min_learning_rate_micro: u32 = 10,
    weight_decay_permille: u32 = 10,
    warmup_steps: u32 = 4000,
    max_steps: u32 = 500000,
    gradient_clip_norm_milli: u32 = 1000,
    initial_temperature_milli: u32 = 70,
    min_temperature_milli: u32 = 15,
    max_temperature_milli: u32 = 500,
    contrastive_loss_weight_milli: u32 = 1000,
    canonical_url_loss_weight_milli: u32 = 150,
    entity_loss_weight_milli: u32 = 200,
    passage_loss_weight_milli: u32 = 250,
    paragraph_loss_weight_milli: u32 = 200,
    link_prediction_loss_weight_milli: u32 = 300,
    distillation_loss_weight_milli: u32 = 150,
    variance_reg_weight_milli: u32 = 50,
    covariance_reg_weight_milli: u32 = 25,
    hard_negative_pool_capacity: u32 = 262144,
    max_negative_model_version_lag: u32 = 2,
    drift_recalibration_threshold_milli: u32 = 180,
    checkpoint_interval_steps: u32 = 2500,
};

pub const VectorIndexConfig = struct {
    schema_version: u32 = 1,
    index_version: u32 = 1,
    target_corpus_documents: u64 = 250000000000,
    semantic_centroids: u32 = 100000,
    retained_dimensions: u32 = 256,
    packed_binary_bytes: u32 = 32,
    primary_dimensions: u32 = 4096,
    shard_count: u32 = 32,
    replication_factor: u32 = 3,
    index_storage_path: []const u8 = "./var/lib/neural_search/vector_index",
    snapshot_storage_path: []const u8 = "./var/lib/neural_search/snapshots",
    default_nprobe: u32 = 16,
    min_nprobe: u32 = 4,
    max_nprobe: u32 = 256,
    cluster_split_threshold: u64 = 5000000,
    centroid_drift_threshold_milli: u32 = 120,
    compaction_tombstone_ratio_permille: u32 = 150,
    segment_alignment_bytes: u32 = 64,
};

pub const ScoringConfig = struct {
    schema_version: u32 = 1,
    quantization_version: u32 = 1,
    vector_bits: u32 = 256,
    packed_bytes: u32 = 32,
    subvector_bits: u32 = 8,
    subvector_count: u32 = 32,
    lookup_table_entries: u32 = 256,
    zero_threshold_nano: i32 = 0,
    enable_stochastic_dithering: bool = false,
    dither_seed: u64 = 98765432101234567,
    dither_amplitude_milli: u32 = 5,
    norm_compensation_enabled: bool = true,
    record_alignment_bytes: u32 = 64,
    scan_block_candidates: u32 = 256,
    cost_reduction_target_multiple: u32 = 10,
};

pub const RankingConfig = struct {
    schema_version: u32 = 1,
    bm25_k1_milli: u32 = 1200,
    bm25_b_milli: u32 = 750,
    title_weight_milli: u32 = 2500,
    heading_weight_milli: u32 = 1800,
    body_weight_milli: u32 = 1000,
    url_weight_milli: u32 = 1500,
    anchor_weight_milli: u32 = 1600,
    metadata_weight_milli: u32 = 1200,
    rrf_k: u32 = 60,
    dense_rrf_weight_milli: u32 = 1000,
    sparse_rrf_weight_milli: u32 = 850,
    fast_candidate_pool_k: u32 = 500,
    expanded_candidate_pool_k: u32 = 5000,
    rerank_top_k: u32 = 200,
    final_top_k: u32 = 25,
    enable_flash_attention_2: bool = true,
    enable_fp8_reranker: bool = true,
};

pub const OrchestrationConfig = struct {
    schema_version: u32 = 1,
    primary_retrieval_budget_ms: u64 = 85,
    hard_search_deadline_ms: u64 = 98,
    sparse_branch_budget_ms: u64 = 35,
    dense_branch_budget_ms: u64 = 40,
    rerank_branch_budget_ms: u64 = 35,
    highlights_branch_budget_ms: u64 = 20,
    verification_branch_budget_ms: u64 = 25,
    enable_speculative_branches: bool = true,
    speculative_threshold_ms: u64 = 18,
    interactive_queue_capacity: u32 = 4096,
    research_queue_capacity: u32 = 512,
    research_max_steps: u32 = 12,
    research_deadline_ms: u64 = 180000,
    gpu_batch_window_ms: u64 = 4,
    gpu_max_batch_size: u32 = 128,
};

pub const CacheConfig = struct {
    schema_version: u32 = 1,
    query_embedding_cache_entries: u32 = 131072,
    query_embedding_ttl_sec: u64 = 7200,
    cluster_posting_cache_bytes: u64 = 4294967296,
    cluster_posting_ttl_sec: u64 = 3600,
    rendered_response_cache_entries: u32 = 65536,
    rendered_response_ttl_sec: u64 = 900,
    coalesce_inflight_requests: bool = true,
    eviction_policy: []const u8 = "segmented_lru",
};

pub const StorageConfig = struct {
    schema_version: u32 = 1,
    document_store_path: []const u8 = "./var/lib/neural_search/documents",
    metadata_store_path: []const u8 = "./var/lib/neural_search/metadata",
    graph_store_path: []const u8 = "./var/lib/neural_search/graph",
    checkpoint_store_path: []const u8 = "./var/lib/neural_search/checkpoints",
    transaction_log_path: []const u8 = "./var/lib/neural_search/txlog",
    sparse_index_path: []const u8 = "./var/lib/neural_search/sparse_index",
    research_state_path: []const u8 = "./var/lib/neural_search/research_state",
    entity_eval_path: []const u8 = "./var/lib/neural_search/entity_eval",
    sync_on_commit: bool = true,
    max_log_segment_bytes: u64 = 134217728,
    compaction_interval_sec: u64 = 1800,
};

pub const DistributedConfig = struct {
    schema_version: u32 = 1,
    node_id: []const u8 = "node-primary-0001",
    bind_address: []const u8 = "0.0.0.0",
    rpc_port: u16 = 9410,
    replication_port: u16 = 9411,
    gossip_port: u16 = 9412,
    consistency_mode: []const u8 = "generation_quorum",
    write_quorum: u32 = 2,
    read_quorum: u32 = 1,
    rpc_timeout_ms: u64 = 45,
    replication_batch_records: u32 = 1024,
    heartbeat_interval_ms: u64 = 500,
    election_timeout_ms: u64 = 2500,
    seed_peers: []const u8 = "127.0.0.1:9410",
};

pub const TelemetryConfig = struct {
    schema_version: u32 = 1,
    metrics_retention_sec: u64 = 86400,
    trace_buffer_events: u32 = 65536,
    trace_sample_permille: u32 = 100,
    histogram_buckets: u32 = 64,
    anomaly_window_size: u32 = 512,
    zscore_threshold_milli: u32 = 3500,
    drift_alert_threshold_milli: u32 = 200,
    export_interval_ms: u64 = 5000,
    telemetry_log_path: []const u8 = "./var/lib/neural_search/telemetry",
};

pub const ApiConfig = struct {
    schema_version: u32 = 1,
    bind_address: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    max_connections: u32 = 8192,
    max_request_body_bytes: u64 = 8388608,
    header_timeout_ms: u64 = 3000,
    request_deadline_ms: u64 = 98,
    research_request_deadline_ms: u64 = 180000,
    keepalive_timeout_ms: u64 = 30000,
};

pub const SystemConfiguration = struct {
    arena: std.heap.ArenaAllocator,
    runtime: RuntimeConfig,
    crawler: CrawlerConfig,
    ingestion: IngestionConfig,
    model: ModelConfig,
    training: TrainingConfig,
    vector_index: VectorIndexConfig,
    scoring: ScoringConfig,
    ranking: RankingConfig,
    orchestration: OrchestrationConfig,
    cache: CacheConfig,
    storage: StorageConfig,
    distributed: DistributedConfig,
    telemetry: TelemetryConfig,
    api: ApiConfig,

    pub fn loadFromDirectory(backing_allocator: std.mem.Allocator, config_dir: []const u8) !SystemConfiguration {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        var cfg = SystemConfiguration{
            .arena = undefined,
            .runtime = .{},
            .crawler = .{},
            .ingestion = .{},
            .model = .{},
            .training = .{},
            .vector_index = .{},
            .scoring = .{},
            .ranking = .{},
            .orchestration = .{},
            .cache = .{},
            .storage = .{},
            .distributed = .{},
            .telemetry = .{},
            .api = .{},
        };

        try parseZonFile(RuntimeConfig, alloc, config_dir, "runtime.zon", &cfg.runtime);
        try parseZonFile(CrawlerConfig, alloc, config_dir, "crawler.zon", &cfg.crawler);
        try parseZonFile(IngestionConfig, alloc, config_dir, "ingestion.zon", &cfg.ingestion);
        try parseZonFile(ModelConfig, alloc, config_dir, "model.zon", &cfg.model);
        try parseZonFile(TrainingConfig, alloc, config_dir, "training.zon", &cfg.training);
        try parseZonFile(VectorIndexConfig, alloc, config_dir, "vector_index.zon", &cfg.vector_index);
        try parseZonFile(ScoringConfig, alloc, config_dir, "scoring.zon", &cfg.scoring);
        try parseZonFile(RankingConfig, alloc, config_dir, "ranking.zon", &cfg.ranking);
        try parseZonFile(OrchestrationConfig, alloc, config_dir, "orchestration.zon", &cfg.orchestration);
        try parseZonFile(CacheConfig, alloc, config_dir, "cache.zon", &cfg.cache);
        try parseZonFile(StorageConfig, alloc, config_dir, "storage.zon", &cfg.storage);
        try parseZonFile(DistributedConfig, alloc, config_dir, "distributed.zon", &cfg.distributed);
        try parseZonFile(TelemetryConfig, alloc, config_dir, "telemetry.zon", &cfg.telemetry);
        try parseZonFile(ApiConfig, alloc, config_dir, "api.zon", &cfg.api);

        try cfg.validateCrossComponentCompatibility();
        try cfg.ensureStorageDirectories();
        cfg.arena = arena;
        return cfg;
    }

    pub fn deinit(self: *SystemConfiguration) void {
        self.arena.deinit();
    }

    pub fn validateCrossComponentCompatibility(self: *const SystemConfiguration) errors.EngineError!void {
        if (self.model.primary_embedding_dim != 4096 or self.vector_index.primary_dimensions != 4096) {
            return error.IncompatibleModelDimension;
        }
        if (self.model.matryoshka_retained_dim != 256 or self.vector_index.retained_dimensions != 256 or self.scoring.vector_bits != 256) {
            return error.IncompatibleModelDimension;
        }
        if (self.model.binary_packed_bytes != 32 or self.vector_index.packed_binary_bytes != 32 or self.scoring.packed_bytes != 32) {
            return error.IncompatibleQuantizationVersion;
        }
        if (self.vector_index.semantic_centroids != 100000) {
            return error.InvalidConfiguration;
        }
        if (self.crawler.target_frontier_capacity_urls < 1400000000000) {
            return error.InvalidConfiguration;
        }
        if (self.orchestration.hard_search_deadline_ms > 100) {
            return error.InvalidConfiguration;
        }
    }

    pub fn ensureStorageDirectories(self: *const SystemConfiguration) !void {
        try std.fs.cwd().makePath(self.runtime.data_root);
        try std.fs.cwd().makePath(self.crawler.frontier_storage_path);
        try std.fs.cwd().makePath(self.crawler.wal_storage_path);
        try std.fs.cwd().makePath(self.ingestion.wal_dir);
        try std.fs.cwd().makePath(self.model.checkpoint_dir);
        try std.fs.cwd().makePath(self.vector_index.index_storage_path);
        try std.fs.cwd().makePath(self.vector_index.snapshot_storage_path);
        try std.fs.cwd().makePath(self.storage.document_store_path);
        try std.fs.cwd().makePath(self.storage.metadata_store_path);
        try std.fs.cwd().makePath(self.storage.graph_store_path);
        try std.fs.cwd().makePath(self.storage.checkpoint_store_path);
        try std.fs.cwd().makePath(self.storage.transaction_log_path);
        try std.fs.cwd().makePath(self.storage.sparse_index_path);
        try std.fs.cwd().makePath(self.storage.research_state_path);
        try std.fs.cwd().makePath(self.storage.entity_eval_path);
        try std.fs.cwd().makePath(self.telemetry.telemetry_log_path);
    }
};

fn parseZonFile(comptime T: type, allocator: std.mem.Allocator, dir_path: []const u8, file_name: []const u8, dest: *T) !void {
    var path_buf: [512]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, file_name });
    const file = std.fs.cwd().openFile(full_path, .{}) catch return;
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r,");
        if (!std.mem.startsWith(u8, line, ".")) continue;
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[1..eq_idx], " \t");
        const val_raw = std.mem.trim(u8, line[eq_idx + 1 ..], " \t,");
        applyField(T, allocator, dest, key, val_raw) catch return error.InvalidConfiguration;
    }
}

fn applyField(comptime T: type, allocator: std.mem.Allocator, dest: *T, key: []const u8, val_raw: []const u8) !void {
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, key)) {
            switch (@typeInfo(field.type)) {
                .Int => {
                    @field(dest, field.name) = try std.fmt.parseInt(field.type, val_raw, 10);
                },
                .Bool => {
                    if (std.mem.eql(u8, val_raw, "true")) {
                        @field(dest, field.name) = true;
                    } else if (std.mem.eql(u8, val_raw, "false")) {
                        @field(dest, field.name) = false;
                    } else {
                        return error.InvalidConfiguration;
                    }
                },
                .Pointer => |ptr_info| {
                    if (ptr_info.size == .Slice and ptr_info.child == u8) {
                        const stripped = std.mem.trim(u8, val_raw, "\"");
                        @field(dest, field.name) = try allocator.dupe(u8, stripped);
                    }
                },
                else => {},
            }
            return;
        }
    }
}
