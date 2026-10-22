const std = @import("std");
const graph_quality = @import("../training/graph_quality.zig");
const checksums = @import("../util/checksums.zig");

pub const GRAPH_EDGE_MAGIC: u32 = 0x47525048;

pub const GraphStore = struct {
    allocator: std.mem.Allocator,
    storage_dir: []u8,
    log_path: []u8,
    mutex: std.Thread.Mutex,
    edges: std.ArrayList(graph_quality.LinkEdgeRecord),
    inbound_counts: std.AutoHashMap(u64, u32),

    pub fn init(allocator: std.mem.Allocator, storage_dir: []const u8) !GraphStore {
        try std.fs.cwd().makePath(storage_dir);
        const dir_copy = try allocator.dupe(u8, storage_dir);
        errdefer allocator.free(dir_copy);
        const log_path = try std.fmt.allocPrint(allocator, "{s}/link_graph.bin", .{storage_dir});
        errdefer allocator.free(log_path);

        var store = GraphStore{
            .allocator = allocator,
            .storage_dir = dir_copy,
            .log_path = log_path,
            .mutex = .{},
            .edges = std.ArrayList(graph_quality.LinkEdgeRecord).init(allocator),
            .inbound_counts = std.AutoHashMap(u64, u32).init(allocator),
        };
        errdefer {
            store.edges.deinit();
            store.inbound_counts.deinit();
        }

        try store.replayFromDisk();
        return store;
    }

    pub fn deinit(self: *GraphStore) void {
        self.edges.deinit();
        self.inbound_counts.deinit();
        self.allocator.free(self.log_path);
        self.allocator.free(self.storage_dir);
    }

    pub fn recordEdge(self: *GraphStore, edge: graph_quality.LinkEdgeRecord) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.appendEdgeToDisk(edge);
        try self.edges.append(edge);
        const gop = try self.inbound_counts.getOrPut(edge.target_domain_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
        } else {
            gop.value_ptr.* +|= 1;
        }
    }

    pub fn getInboundDegree(self: *GraphStore, domain_id: u64) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.inbound_counts.get(domain_id) orelse 0;
    }

    fn appendEdgeToDisk(self: *GraphStore, edge: graph_quality.LinkEdgeRecord) !void {
        var file = try std.fs.cwd().createFile(self.log_path, .{ .truncate = false, .read = true });
        defer file.close();
        try file.seekFromEnd(0);

        var payload: [36]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], edge.source_doc_id, .little);
        std.mem.writeInt(u64, payload[8..16], edge.target_doc_id, .little);
        std.mem.writeInt(u64, payload[16..24], edge.source_domain_id, .little);
        std.mem.writeInt(u64, payload[24..32], edge.target_domain_id, .little);
        std.mem.writeInt(u16, payload[32..34], edge.anchor_relevance_permille, .little);
        payload[34] = if (edge.is_nofollow) 1 else 0;
        payload[35] = if (edge.same_registrar_cluster) 1 else 0;

        const crc = checksums.crc32(&payload);
        var frame: [44]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], GRAPH_EDGE_MAGIC, .little);
        std.mem.writeInt(u32, frame[4..8], crc, .little);
        @memcpy(frame[8..44], &payload);
        try file.writeAll(&frame);
    }

    fn replayFromDisk(self: *GraphStore) !void {
        const file = std.fs.cwd().openFile(self.log_path, .{}) catch return;
        defer file.close();

        var frame: [44]u8 = undefined;
        while (true) {
            const n = try file.readAll(&frame);
            if (n < frame.len) break;
            const magic = std.mem.readInt(u32, frame[0..4], .little);
            if (magic != GRAPH_EDGE_MAGIC) break;
            const expected_crc = std.mem.readInt(u32, frame[4..8], .little);
            const payload = frame[8..44];
            if (!checksums.verifyCrc32(payload, expected_crc)) break;

            const edge = graph_quality.LinkEdgeRecord{
                .source_doc_id = std.mem.readInt(u64, payload[0..8], .little),
                .target_doc_id = std.mem.readInt(u64, payload[8..16], .little),
                .source_domain_id = std.mem.readInt(u64, payload[16..24], .little),
                .target_domain_id = std.mem.readInt(u64, payload[24..32], .little),
                .anchor_relevance_permille = std.mem.readInt(u16, payload[32..34], .little),
                .is_nofollow = payload[34] != 0,
                .same_registrar_cluster = payload[35] != 0,
            };
            try self.edges.append(edge);
            const gop = try self.inbound_counts.getOrPut(edge.target_domain_id);
            if (!gop.found_existing) {
                gop.value_ptr.* = 1;
            } else {
                gop.value_ptr.* +|= 1;
            }
        }
    }
};
