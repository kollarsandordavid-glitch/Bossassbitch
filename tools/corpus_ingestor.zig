const std = @import("std");
const core = @import("engine_core");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_dir: []const u8 = "./settings";
    var target_url: []const u8 = "https://ziglang.org/learn/overview/";
    var html_payload: []const u8 = "<html><head><title>Zig System Overview</title></head><body><h1>High Performance Systems Programming</h1><p>Zig enables deterministic memory management, SIMD vectorization across x86_64 AVX-512 and ARM SVE, and explicit error handling.</p></body></html>";

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--config-dir=")) {
            config_dir = arg["--config-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--url=")) {
            target_url = arg["--url=".len..];
        } else if (std.mem.startsWith(u8, arg, "--html=")) {
            html_payload = arg["--html=".len..];
        }
    }

    var cfg = try core.runtime.configuration.SystemConfiguration.loadFromDirectory(allocator, config_dir);
    defer cfg.deinit();

    var crawler = try core.crawl.crawl_coordinator.CrawlCoordinator.init(allocator, cfg.crawler);
    defer crawler.deinit();

    var stream = try core.ingestion.stream_engine.StreamEngine.init(allocator, cfg.ingestion);
    defer stream.deinit();

    var doc_store = try core.storage.document_store.DocumentStore.init(allocator, cfg.storage.document_store_path);
    defer doc_store.deinit();

    var extracted = try crawler.ingestHtmlPageDirectly(target_url, html_payload);
    defer extracted.deinit(allocator);

    const verdict = stream.filter.evaluateDocument(&extracted);
    if (verdict.accepted) {
        _ = try stream.publishDocumentEvent(
            extracted.doc_id,
            extracted.domain_id,
            extracted.canonical_url,
            extracted.title,
            extracted.body_text,
            extracted.language,
            extracted.published_at_ms,
            verdict.quality_score_permille,
            verdict.spam_probability_permille,
            true,
        );
        try doc_store.putDocument(.{
            .doc_id = extracted.doc_id,
            .canonical_url = extracted.canonical_url,
            .original_url = extracted.original_url,
            .title = extracted.title,
            .description = extracted.description,
            .body_text = extracted.body_text,
            .language = extracted.language,
            .domain_id = extracted.domain_id,
            .content_hash = extracted.content_hash,
            .simhash = extracted.simhash,
            .published_at_ms = extracted.published_at_ms,
            .fetched_at_ms = extracted.fetched_at_ms,
            .quality_permille = verdict.quality_score_permille,
        });
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "{{\"tool\":\"corpus-ingestor\",\"status\":\"completed\",\"doc_id\":{d},\"accepted\":{},\"quality_permille\":{d}}}\n",
        .{ extracted.doc_id, verdict.accepted, verdict.quality_score_permille },
    );
}
