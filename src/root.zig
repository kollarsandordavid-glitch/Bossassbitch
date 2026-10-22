pub const runtime = struct {
    pub const lifecycle = @import("runtime/lifecycle.zig");
    pub const configuration = @import("runtime/configuration.zig");
    pub const allocator = @import("runtime/allocator.zig");
    pub const errors = @import("runtime/errors.zig");
    pub const scheduler = @import("runtime/scheduler.zig");
    pub const cancellation = @import("runtime/cancellation.zig");
    pub const worker_pool = @import("runtime/worker_pool.zig");
};

pub const network = struct {
    pub const http_client = @import("network/http_client.zig");
    pub const http_server = @import("network/http_server.zig");
    pub const tls = @import("network/tls.zig");
    pub const protocol = @import("network/protocol.zig");
    pub const serialization = @import("network/serialization.zig");
    pub const transport = @import("network/transport.zig");
};

pub const crawl = struct {
    pub const frontier = @import("crawl/frontier.zig");
    pub const frontier_partition = @import("crawl/frontier_partition.zig");
    pub const fetcher = @import("crawl/fetcher.zig");
    pub const browser_runtime = @import("crawl/browser_runtime.zig");
    pub const dom_executor = @import("crawl/dom_executor.zig");
    pub const html_parser = @import("crawl/html_parser.zig");
    pub const document_extractor = @import("crawl/document_extractor.zig");
    pub const canonicalization = @import("crawl/canonicalization.zig");
    pub const url_normalization = @import("crawl/url_normalization.zig");
    pub const deduplication = @import("crawl/deduplication.zig");
    pub const recrawl_scheduler = @import("crawl/recrawl_scheduler.zig");
    pub const domain_velocity = @import("crawl/domain_velocity.zig");
    pub const crawl_coordinator = @import("crawl/crawl_coordinator.zig");
    pub const crawl_state = @import("crawl/crawl_state.zig");
};

pub const ingestion = struct {
    pub const stream_engine = @import("ingestion/stream_engine.zig");
    pub const write_ahead_log = @import("ingestion/write_ahead_log.zig");
    pub const event_codec = @import("ingestion/event_codec.zig");
    pub const partition_router = @import("ingestion/partition_router.zig");
    pub const backpressure = @import("ingestion/backpressure.zig");
    pub const content_filter = @import("ingestion/content_filter.zig");
    pub const spam_classifier = @import("ingestion/spam_classifier.zig");
    pub const quality_features = @import("ingestion/quality_features.zig");
    pub const live_index_writer = @import("ingestion/live_index_writer.zig");
};

pub const models = struct {
    pub const tokenizer = @import("models/tokenizer.zig");
    pub const tensor = @import("models/tensor.zig");
    pub const tensor_ops = @import("models/tensor_ops.zig");
    pub const transformer = @import("models/transformer.zig");
    pub const attention = @import("models/attention.zig");
    pub const dual_encoder = @import("models/dual_encoder.zig");
    pub const embedding_service = @import("models/embedding_service.zig");
    pub const paragraph_predictor = @import("models/paragraph_predictor.zig");
    pub const structural_encoder = @import("models/structural_encoder.zig");
    pub const entity_classifier = @import("models/entity_classifier.zig");
    pub const passage_extractor = @import("models/passage_extractor.zig");
    pub const checkpoint = @import("models/checkpoint.zig");
    pub const model_registry = @import("models/model_registry.zig");
    pub const model_version = @import("models/model_version.zig");
    pub const inference_client = @import("models/inference_client.zig");
};

pub const training = struct {
    pub const training_runtime = @import("training/training_runtime.zig");
    pub const contrastive_loss = @import("training/contrastive_loss.zig");
    pub const multitask_loss = @import("training/multitask_loss.zig");
    pub const optimizer = @import("training/optimizer.zig");
    pub const temperature_scaling = @import("training/temperature_scaling.zig");
    pub const regularization = @import("training/regularization.zig");
    pub const negative_mining = @import("training/negative_mining.zig");
    pub const graph_quality = @import("training/graph_quality.zig");
    pub const curriculum = @import("training/curriculum.zig");
    pub const checkpoint_transfer = @import("training/checkpoint_transfer.zig");
    pub const drift_detection = @import("training/drift_detection.zig");
    pub const training_coordinator = @import("training/training_coordinator.zig");
};

pub const index = struct {
    pub const vector_index = @import("index/vector_index.zig");
    pub const binary_quantization = @import("index/binary_quantization.zig");
    pub const centroid_manager = @import("index/centroid_manager.zig");
    pub const clustering = @import("index/clustering.zig");
    pub const shard_manager = @import("index/shard_manager.zig");
    pub const posting_lists = @import("index/posting_lists.zig");
    pub const metadata_index = @import("index/metadata_index.zig");
    pub const filter_engine = @import("index/filter_engine.zig");
    pub const deletion_manager = @import("index/deletion_manager.zig");
    pub const compaction = @import("index/compaction.zig");
    pub const mmap_store = @import("index/mmap_store.zig");
    pub const nvme_store = @import("index/nvme_store.zig");
    pub const replication = @import("index/replication.zig");
    pub const consistency = @import("index/consistency.zig");
    pub const snapshots = @import("index/snapshots.zig");
    pub const recovery = @import("index/recovery.zig");
};

pub const scoring = struct {
    pub const simd_dispatch = @import("scoring/simd_dispatch.zig");
    pub const scalar_kernel = @import("scoring/scalar_kernel.zig");
    pub const x86_avx2 = @import("scoring/x86_avx2.zig");
    pub const x86_avx512 = @import("scoring/x86_avx512.zig");
    pub const arm_neon = @import("scoring/arm_neon.zig");
    pub const arm_sve = @import("scoring/arm_sve.zig");
    pub const lookup_tables = @import("scoring/lookup_tables.zig");
    pub const binary_scoring = @import("scoring/binary_scoring.zig");
    pub const norm_compensation = @import("scoring/norm_compensation.zig");
    pub const numeric_stability = @import("scoring/numeric_stability.zig");
    pub const candidate_scanner = @import("scoring/candidate_scanner.zig");
};

pub const retrieval = struct {
    pub const query_parser = @import("retrieval/query_parser.zig");
    pub const query_router = @import("retrieval/query_router.zig");
    pub const sparse_index = @import("retrieval/sparse_index.zig");
    pub const bm25 = @import("retrieval/bm25.zig");
    pub const dense_search = @import("retrieval/dense_search.zig");
    pub const cluster_probe = @import("retrieval/cluster_probe.zig");
    pub const scatter_gather = @import("retrieval/scatter_gather.zig");
    pub const candidate_merge = @import("retrieval/candidate_merge.zig");
    pub const reranker = @import("retrieval/reranker.zig");
    pub const reciprocal_rank_fusion = @import("retrieval/reciprocal_rank_fusion.zig");
    pub const ranking_features = @import("retrieval/ranking_features.zig");
    pub const citation_verifier = @import("retrieval/citation_verifier.zig");
};

pub const orchestration = struct {
    pub const query_dag = @import("orchestration/query_dag.zig");
    pub const dag_scheduler = @import("orchestration/dag_scheduler.zig");
    pub const deadlines = @import("orchestration/deadlines.zig");
    pub const speculative_execution = @import("orchestration/speculative_execution.zig");
    pub const branch_cancellation = @import("orchestration/branch_cancellation.zig");
    pub const research_pipeline = @import("orchestration/research_pipeline.zig");
    pub const gpu_scheduler = @import("orchestration/gpu_scheduler.zig");
    pub const workload_coordinator = @import("orchestration/workload_coordinator.zig");
};

pub const highlights = struct {
    pub const paragraph_segmentation = @import("highlights/paragraph_segmentation.zig");
    pub const context_windows = @import("highlights/context_windows.zig");
    pub const relevance_scoring = @import("highlights/relevance_scoring.zig");
    pub const highlight_extractor = @import("highlights/highlight_extractor.zig");
    pub const source_alignment = @import("highlights/source_alignment.zig");
};

pub const cache = struct {
    pub const query_embeddings = @import("cache/query_embeddings.zig");
    pub const cluster_postings = @import("cache/cluster_postings.zig");
    pub const rendered_results = @import("cache/rendered_results.zig");
    pub const cache_coordinator = @import("cache/cache_coordinator.zig");
    pub const invalidation = @import("cache/invalidation.zig");
};

pub const api = struct {
    pub const routes = @import("api/routes.zig");
    pub const search_handler = @import("api/search_handler.zig");
    pub const ingestion_handler = @import("api/ingestion_handler.zig");
    pub const research_handler = @import("api/research_handler.zig");
    pub const highlights_handler = @import("api/highlights_handler.zig");
    pub const entity_handler = @import("api/entity_handler.zig");
    pub const request_codec = @import("api/request_codec.zig");
    pub const response_codec = @import("api/response_codec.zig");
};

pub const telemetry = struct {
    pub const metrics = @import("telemetry/metrics.zig");
    pub const tracing = @import("telemetry/tracing.zig");
    pub const latency_histograms = @import("telemetry/latency_histograms.zig");
    pub const anomaly_detection = @import("telemetry/anomaly_detection.zig");
    pub const crawler_anomalies = @import("telemetry/crawler_anomalies.zig");
    pub const model_drift = @import("telemetry/model_drift.zig");
    pub const index_health = @import("telemetry/index_health.zig");
    pub const exporters = @import("telemetry/exporters.zig");
};

pub const storage = struct {
    pub const document_store = @import("storage/document_store.zig");
    pub const metadata_store = @import("storage/metadata_store.zig");
    pub const graph_store = @import("storage/graph_store.zig");
    pub const checkpoint_store = @import("storage/checkpoint_store.zig");
    pub const transaction_log = @import("storage/transaction_log.zig");
};

pub const util = struct {
    pub const hashing = @import("util/hashing.zig");
    pub const checksums = @import("util/checksums.zig");
    pub const compression = @import("util/compression.zig");
    pub const bloom_filter = @import("util/bloom_filter.zig");
    pub const sketches = @import("util/sketches.zig");
    pub const binary_codec = @import("util/binary_codec.zig");
    pub const time = @import("util/time.zig");
    pub const platform = @import("util/platform.zig");
};
