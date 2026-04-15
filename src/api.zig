const std = @import("std");
const Io = std.Io;
const db_mod = @import("db.zig");
const path_norm = @import("path_norm.zig");
const vector_mod = @import("vector.zig");

/// Get current Unix epoch timestamp in seconds.
fn currentUnixSeconds(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
}

pub const ChunkInput = struct {
    content: []const u8,
    embedding: ?[]const f32 = null,
};

pub const DocumentInput = struct {
    collection: []const u8,
    path: []const u8,
    hash: []const u8,
    modified_at: i64,
    chunks: []const ChunkInput,
};

pub const QueryInput = struct {
    query_text: []const u8,
    query_embedding: ?[]const f32 = null,
    collection: ?[]const u8 = null,
    limit: usize = 10,
    lexical_weight: f64 = 0.45,
    vector_weight: f64 = 0.55,
};

/// Input to Engine.writeMemory.
pub const MemoryInput = struct {
    /// Namespaced key, e.g. "user:name" or "user:local:pref:language".
    memory_key: []const u8,
    /// Semantic category, e.g. "profile", "preference", "fact".
    mem_type: []const u8,
    /// Who wrote this, e.g. "manual", "inference", "tool".
    source: []const u8,
    /// The value to store.
    content: []const u8,
    /// How certain we are: 0.0 (guess) … 1.0 (verified fact).
    confidence: f64,
    /// How important this is for future recall: 0.0 … 1.0.
    salience: f64,
    /// Optional Unix timestamp after which this memory expires.
    expires_at: ?i64 = null,
};

/// Re-export so callers only need to import api.zig.
pub const MemoryRow = db_mod.MemoryRow;

pub const SearchHit = struct {
    chunk_id: i64,
    collection: []u8,
    path: []u8,
    content: []u8,
    lexical_score: f64,
    vector_score: f64,
    fused_score: f64,

    pub fn deinit(self: SearchHit, allocator: std.mem.Allocator) void {
        allocator.free(self.collection);
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    io: Io,
    db: db_mod.Db,

    pub fn open(allocator: std.mem.Allocator, io: Io, db_path: []const u8) !Engine {
        var db = try db_mod.Db.open(allocator, io, db_path);
        errdefer db.close();
        try db.initSchema();
        return .{ .allocator = allocator, .io = io, .db = db };
    }

    pub fn close(self: *Engine) void {
        self.db.close();
    }

    // ── Memory (key-value) operations ─────────────────────────────────────────
    // All timestamps are derived from currentUnixSeconds() internally so
    // callers never have to manage them.

    /// Write or update a key-value memory entry.
    /// If `memory_key` already exists, the previous entry is superseded and a
    /// new revision is appended to the append-only `memory_events` log.
    pub fn writeMemory(self: *Engine, input: MemoryInput) !void {
        try self.db.writeMemory(.{
            .memory_key = input.memory_key,
            .mem_type = input.mem_type,
            .source = input.source,
            .content = input.content,
            .confidence = input.confidence,
            .salience = input.salience,
            .now_ts = currentUnixSeconds(self.io),
            .expires_at = input.expires_at,
        });
    }

    /// Tombstone a memory entry.  The key disappears from ranked recall but the
    /// full audit trail is preserved in `memory_events`.
    pub fn deleteMemory(self: *Engine, memory_key: []const u8, source: []const u8) !void {
        try self.db.deleteMemory(memory_key, source, currentUnixSeconds(self.io));
    }

    /// Update the `last_accessed_at` timestamp of an existing memory entry.
    /// This re-weights the entry in recency-based ranking without changing the
    /// stored content.  Returns `error.MemoryNotFound` if the key does not exist.
    pub fn touchMemory(self: *Engine, memory_key: []const u8, source: []const u8) !void {
        try self.db.touchMemory(memory_key, source, currentUnixSeconds(self.io));
    }

    /// Return the top `limit` memories sorted by the ranking formula:
    ///   rank = 0.45 * salience + 0.35 * confidence + 0.20 * recency_decay
    /// Expired entries are excluded.  Caller owns the returned slice; free with
    /// `freeMemoryRows`.
    pub fn listMemoriesRanked(self: *Engine, limit: usize) ![]MemoryRow {
        return self.db.listMemoriesRanked(self.allocator, currentUnixSeconds(self.io), limit);
    }

    /// Convenience: return the raw content string for a single memory key, or
    /// null if it does not exist / has been deleted.  Caller owns the returned
    /// string; free with `allocator.free`.
    pub fn getMemoryContent(self: *Engine, memory_key: []const u8) !?[]u8 {
        return self.db.currentMemoryContent(self.allocator, memory_key);
    }

    // ── Document / chunk operations ───────────────────────────────────────────

    pub fn upsertDocument(self: *Engine, input: DocumentInput) !void {
        const path_id = try path_norm.normalizePathIdentity(self.allocator, input.path);
        defer path_id.deinit(self.allocator);

        var chunks = std.array_list.Managed(db_mod.DocumentChunkInput).init(self.allocator);
        defer chunks.deinit();
        try chunks.ensureTotalCapacity(input.chunks.len);

        for (input.chunks) |chunk| {
            chunks.appendAssumeCapacity(.{
                .content = chunk.content,
                .embedding = chunk.embedding,
            });
        }

        try self.db.upsertDocument(.{
            .collection = input.collection,
            .path = input.path,
            .path_key = path_id.path_key,
            .path_search = path_id.search_key,
            .hash = input.hash,
            .modified_at = input.modified_at,
            .chunks = chunks.items,
        });
    }

    pub fn hybridQuery(self: *Engine, input: QueryInput) ![]SearchHit {
        if (input.limit == 0) return self.allocator.alloc(SearchHit, 0);

        const normalized = normalizeWeights(input.lexical_weight, input.vector_weight);
        const lexical_limit = input.limit * 4;

        const lexical_hits = try self.db.lexicalSearchChunks(
            self.allocator,
            input.query_text,
            input.collection,
            lexical_limit,
        );
        defer db_mod.Db.freeLexicalChunkHits(self.allocator, lexical_hits);

        const vector_hits = if (input.query_embedding) |query_embedding|
            try self.collectVectorHits(query_embedding, input.collection, input.limit)
        else
            try self.allocator.alloc(db_mod.VectorChunkHit, 0);
        defer db_mod.Db.freeVectorChunkHits(self.allocator, vector_hits);

        var merged = std.AutoHashMap(i64, SearchHit).init(self.allocator);
        errdefer {
            var it = merged.valueIterator();
            while (it.next()) |row| row.deinit(self.allocator);
            merged.deinit();
        }

        for (lexical_hits) |row| {
            const entry = merged.getPtr(row.chunk_id);
            if (entry) |hit| {
                hit.lexical_score = @max(hit.lexical_score, row.lexical_score);
                hit.fused_score = (normalized.lexical * hit.lexical_score) + (normalized.vector * hit.vector_score);
                continue;
            }

            try merged.put(row.chunk_id, .{
                .chunk_id = row.chunk_id,
                .collection = try self.allocator.dupe(u8, row.collection),
                .path = try self.allocator.dupe(u8, row.path),
                .content = try self.allocator.dupe(u8, row.content),
                .lexical_score = row.lexical_score,
                .vector_score = 0.0,
                .fused_score = normalized.lexical * row.lexical_score,
            });
        }

        for (vector_hits) |row| {
            const vector_score = vector_mod.cosineDistanceToUnitScore(row.distance);
            const entry = merged.getPtr(row.chunk_id);
            if (entry) |hit| {
                hit.vector_score = @max(hit.vector_score, vector_score);
                hit.fused_score = (normalized.lexical * hit.lexical_score) + (normalized.vector * hit.vector_score);
                continue;
            }

            try merged.put(row.chunk_id, .{
                .chunk_id = row.chunk_id,
                .collection = try self.allocator.dupe(u8, row.collection),
                .path = try self.allocator.dupe(u8, row.path),
                .content = try self.allocator.dupe(u8, row.content),
                .lexical_score = 0.0,
                .vector_score = vector_score,
                .fused_score = normalized.vector * vector_score,
            });
        }

        var rows = std.array_list.Managed(SearchHit).init(self.allocator);
        errdefer {
            for (rows.items) |row| row.deinit(self.allocator);
            rows.deinit();
        }

        var it = merged.iterator();
        while (it.next()) |entry| {
            try rows.append(entry.value_ptr.*);
        }
        merged.deinit();

        std.sort.heap(SearchHit, rows.items, {}, searchHitLessThan);
        if (rows.items.len > input.limit) {
            for (rows.items[input.limit..]) |row| row.deinit(self.allocator);
            rows.shrinkRetainingCapacity(input.limit);
        }

        return rows.toOwnedSlice();
    }

    fn collectVectorHits(
        self: *Engine,
        query_embedding: []const f32,
        collection: ?[]const u8,
        limit: usize,
    ) ![]db_mod.VectorChunkHit {
        const max_global = vector_mod.recommendedGlobalK(limit, 8);
        const global_hits = try self.db.vectorSearchChunksGlobal(self.allocator, query_embedding, max_global);
        defer db_mod.Db.freeVectorChunkHits(self.allocator, global_hits);

        if (global_hits.len == 0) return self.allocator.alloc(db_mod.VectorChunkHit, 0);

        var adapters = std.array_list.Managed(vector_mod.VectorHit).init(self.allocator);
        defer adapters.deinit();

        var id_to_index = std.StringHashMap(usize).init(self.allocator);
        defer id_to_index.deinit();

        for (global_hits, 0..) |hit, idx| {
            const id = try std.fmt.allocPrint(self.allocator, "{d}", .{hit.chunk_id});
            errdefer self.allocator.free(id);
            try adapters.append(.{
                .id = id,
                .collection = hit.collection,
                .distance = hit.distance,
            });
            try id_to_index.put(id, idx);
        }
        defer for (adapters.items) |hit| self.allocator.free(hit.id);

        const filtered = try vector_mod.adaptiveCollectionFilter(
            self.allocator,
            adapters.items,
            limit,
            collection,
        );
        defer self.allocator.free(filtered);

        var rows = std.array_list.Managed(db_mod.VectorChunkHit).init(self.allocator);
        errdefer {
            for (rows.items) |row| row.deinit(self.allocator);
            rows.deinit();
        }

        for (filtered) |selected| {
            const idx = id_to_index.get(selected.id) orelse continue;
            const source = global_hits[idx];
            try rows.append(.{
                .chunk_id = source.chunk_id,
                .collection = try self.allocator.dupe(u8, source.collection),
                .path = try self.allocator.dupe(u8, source.path),
                .content = try self.allocator.dupe(u8, source.content),
                .distance = source.distance,
            });
        }

        return rows.toOwnedSlice();
    }
};

pub fn freeSearchHits(allocator: std.mem.Allocator, hits: []SearchHit) void {
    for (hits) |row| row.deinit(allocator);
    allocator.free(hits);
}

/// Free a slice returned by `Engine.listMemoriesRanked`.
pub fn freeMemoryRows(allocator: std.mem.Allocator, rows: []MemoryRow) void {
    db_mod.Db.freeMemoryRows(allocator, rows);
}

fn normalizeWeights(lexical: f64, vector: f64) struct { lexical: f64, vector: f64 } {
    const l = std.math.clamp(lexical, 0.0, 1.0);
    const v = std.math.clamp(vector, 0.0, 1.0);
    if (l == 0.0 and v == 0.0) return .{ .lexical = 0.5, .vector = 0.5 };
    const sum = l + v;
    return .{ .lexical = l / sum, .vector = v / sum };
}

fn searchHitLessThan(_: void, a: SearchHit, b: SearchHit) bool {
    if (a.fused_score == b.fused_score) {
        if (a.vector_score == b.vector_score) return a.lexical_score > b.lexical_score;
        return a.vector_score > b.vector_score;
    }
    return a.fused_score > b.fused_score;
}

test "engine hybrid query supports adaptive collection filtering" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var engine = try Engine.open(allocator, io, ":memory:");
    defer engine.close();

    const chunk_other = [_]ChunkInput{
        .{ .content = "vector memory from other collection", .embedding = &[_]f32{ 1.0, 0.0 } },
    };
    try engine.upsertDocument(.{
        .collection = "other",
        .path = "notes/other.md",
        .hash = "h1",
        .modified_at = 10,
        .chunks = &chunk_other,
    });

    const chunk_work = [_]ChunkInput{
        .{ .content = "project memory in work collection", .embedding = &[_]f32{ 0.8, 0.2 } },
    };
    try engine.upsertDocument(.{
        .collection = "work",
        .path = "notes/work.md",
        .hash = "h2",
        .modified_at = 11,
        .chunks = &chunk_work,
    });

    const hits = try engine.hybridQuery(.{
        .query_text = "no lexical match",
        .query_embedding = &[_]f32{ 1.0, 0.0 },
        .collection = "work",
        .limit = 1,
        .lexical_weight = 0.1,
        .vector_weight = 0.9,
    });
    defer freeSearchHits(allocator, hits);

    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("work", hits[0].collection);
}
