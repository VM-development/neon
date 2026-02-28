const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    SqliteFailure,
    InvalidScore,
    MemoryNotFound,
};

pub const MemoryWriteInput = struct {
    memory_key: []const u8,
    mem_type: []const u8,
    source: []const u8,
    content: []const u8,
    confidence: f64,
    salience: f64,
    now_ts: i64,
    expires_at: ?i64 = null,
};

pub const MemoryRow = struct {
    memory_key: []u8,
    mem_type: []u8,
    source: []u8,
    content: []u8,
    confidence: f64,
    salience: f64,
    created_at: i64,
    last_accessed_at: i64,
    expires_at: ?i64,
    rank_score: f64,

    pub fn deinit(self: MemoryRow, allocator: std.mem.Allocator) void {
        allocator.free(self.memory_key);
        allocator.free(self.mem_type);
        allocator.free(self.source);
        allocator.free(self.content);
    }
};

pub const DocumentChunkInput = struct {
    content: []const u8,
    embedding: ?[]const f32 = null,
};

pub const DocumentUpsertInput = struct {
    collection: []const u8,
    path: []const u8,
    path_key: []const u8,
    path_search: []const u8,
    hash: []const u8,
    modified_at: i64,
    chunks: []const DocumentChunkInput,
};

pub const LexicalChunkHit = struct {
    chunk_id: i64,
    collection: []u8,
    path: []u8,
    content: []u8,
    bm25_score: f64,
    lexical_score: f64,

    pub fn deinit(self: LexicalChunkHit, allocator: std.mem.Allocator) void {
        allocator.free(self.collection);
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

pub const VectorChunkHit = struct {
    chunk_id: i64,
    collection: []u8,
    path: []u8,
    content: []u8,
    distance: f64,

    pub fn deinit(self: VectorChunkHit, allocator: std.mem.Allocator) void {
        allocator.free(self.collection);
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

const CurrentMemory = struct {
    current_event_id: []u8,
    mem_type: []u8,
    content: []u8,
    confidence: f64,
    salience: f64,
    created_at: i64,
    expires_at: ?i64,

    fn deinit(self: CurrentMemory, allocator: std.mem.Allocator) void {
        allocator.free(self.current_event_id);
        allocator.free(self.mem_type);
        allocator.free(self.content);
    }
};

pub const Db = struct {
    handle: *c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Db {
        const zpath = try allocator.dupeZ(u8, path);
        defer allocator.free(zpath);

        var raw_handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            zpath.ptr,
            &raw_handle,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX,
            null,
        );
        if (rc != c.SQLITE_OK or raw_handle == null) return error.SqliteFailure;

        return .{
            .handle = raw_handle.?,
            .allocator = allocator,
        };
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close_v2(self.handle);
    }

    pub fn initSchema(self: *Db) !void {
        try self.exec(
            \\PRAGMA foreign_keys = ON;
            \\PRAGMA journal_mode = WAL;
            \\
            \\CREATE TABLE IF NOT EXISTS documents (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  collection TEXT NOT NULL,
            \\  path TEXT NOT NULL,
            \\  path_key TEXT NOT NULL,
            \\  path_search TEXT NOT NULL,
            \\  hash TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL,
            \\  modified_at INTEGER NOT NULL,
            \\  active INTEGER NOT NULL DEFAULT 1,
            \\  UNIQUE(collection, path_key)
            \\);
            \\
            \\CREATE INDEX IF NOT EXISTS idx_documents_collection_active ON documents(collection, active);
            \\
            \\CREATE TABLE IF NOT EXISTS document_chunks (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  document_id INTEGER NOT NULL,
            \\  collection TEXT NOT NULL,
            \\  chunk_index INTEGER NOT NULL,
            \\  content TEXT NOT NULL,
            \\  embedding BLOB,
            \\  embedding_dim INTEGER NOT NULL DEFAULT 0,
            \\  UNIQUE(document_id, chunk_index),
            \\  FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
            \\);
            \\
            \\CREATE INDEX IF NOT EXISTS idx_document_chunks_document ON document_chunks(document_id);
            \\CREATE INDEX IF NOT EXISTS idx_document_chunks_collection ON document_chunks(collection);
            \\
            \\CREATE VIRTUAL TABLE IF NOT EXISTS document_chunks_fts USING fts5(
            \\  content,
            \\  collection UNINDEXED,
            \\  path UNINDEXED,
            \\  chunk_id UNINDEXED,
            \\  tokenize='unicode61 remove_diacritics 2'
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS memory_events (
            \\  event_id TEXT PRIMARY KEY,
            \\  memory_key TEXT NOT NULL,
            \\  op TEXT NOT NULL CHECK(op IN ('upsert', 'delete')),
            \\  type TEXT NOT NULL,
            \\  source TEXT NOT NULL,
            \\  content TEXT NOT NULL,
            \\  confidence REAL NOT NULL CHECK(confidence >= 0.0 AND confidence <= 1.0),
            \\  salience REAL NOT NULL CHECK(salience >= 0.0 AND salience <= 1.0),
            \\  created_at INTEGER NOT NULL,
            \\  last_accessed_at INTEGER NOT NULL,
            \\  expires_at INTEGER,
            \\  supersedes TEXT,
            \\  metadata_json TEXT,
            \\  FOREIGN KEY(supersedes) REFERENCES memory_events(event_id)
            \\);
            \\
            \\CREATE INDEX IF NOT EXISTS idx_memory_events_key_created ON memory_events(memory_key, created_at DESC);
            \\
            \\CREATE TABLE IF NOT EXISTS memories (
            \\  memory_key TEXT PRIMARY KEY,
            \\  current_event_id TEXT NOT NULL,
            \\  type TEXT NOT NULL,
            \\  source TEXT NOT NULL,
            \\  content TEXT NOT NULL,
            \\  confidence REAL NOT NULL CHECK(confidence >= 0.0 AND confidence <= 1.0),
            \\  salience REAL NOT NULL CHECK(salience >= 0.0 AND salience <= 1.0),
            \\  created_at INTEGER NOT NULL,
            \\  last_accessed_at INTEGER NOT NULL,
            \\  expires_at INTEGER,
            \\  updated_at INTEGER NOT NULL,
            \\  FOREIGN KEY(current_event_id) REFERENCES memory_events(event_id)
            \\);
            \\
            \\CREATE INDEX IF NOT EXISTS idx_memories_rank ON memories(salience DESC, confidence DESC, last_accessed_at DESC);
        );
    }

    pub fn upsertDocument(self: *Db, input: DocumentUpsertInput) !void {
        const now_ts = std.time.timestamp();

        try self.exec("BEGIN IMMEDIATE;");
        var committed = false;
        defer if (!committed) self.exec("ROLLBACK;") catch {};

        const upsert_doc = try self.prepare(
            \\INSERT INTO documents(
            \\  collection, path, path_key, path_search, hash,
            \\  created_at, modified_at, active
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
            \\ON CONFLICT(collection, path_key) DO UPDATE SET
            \\  path = excluded.path,
            \\  path_search = excluded.path_search,
            \\  hash = excluded.hash,
            \\  modified_at = excluded.modified_at,
            \\  active = 1
        );
        defer _ = c.sqlite3_finalize(upsert_doc);

        try bindText(upsert_doc, 1, input.collection);
        try bindText(upsert_doc, 2, input.path);
        try bindText(upsert_doc, 3, input.path_key);
        try bindText(upsert_doc, 4, input.path_search);
        try bindText(upsert_doc, 5, input.hash);
        try bindInt(upsert_doc, 6, now_ts);
        try bindInt(upsert_doc, 7, input.modified_at);
        try stepDone(upsert_doc);

        const doc_id = try self.documentId(input.collection, input.path_key) orelse return error.SqliteFailure;

        const clear_chunks = try self.prepare("DELETE FROM document_chunks WHERE document_id = ?;");
        defer _ = c.sqlite3_finalize(clear_chunks);
        try bindInt(clear_chunks, 1, doc_id);
        try stepDone(clear_chunks);

        const clear_fts = try self.prepare("DELETE FROM document_chunks_fts WHERE collection = ? AND path = ?;");
        defer _ = c.sqlite3_finalize(clear_fts);
        try bindText(clear_fts, 1, input.collection);
        try bindText(clear_fts, 2, input.path);
        try stepDone(clear_fts);

        const insert_chunk = try self.prepare(
            \\INSERT INTO document_chunks(document_id, collection, chunk_index, content, embedding, embedding_dim)
            \\VALUES (?, ?, ?, ?, ?, ?)
        );
        defer _ = c.sqlite3_finalize(insert_chunk);

        const insert_fts = try self.prepare(
            \\INSERT INTO document_chunks_fts(content, collection, path, chunk_id)
            \\VALUES (?, ?, ?, ?)
        );
        defer _ = c.sqlite3_finalize(insert_fts);

        for (input.chunks, 0..) |chunk, idx| {
            _ = c.sqlite3_reset(insert_chunk);
            _ = c.sqlite3_clear_bindings(insert_chunk);

            try bindInt(insert_chunk, 1, doc_id);
            try bindText(insert_chunk, 2, input.collection);
            try bindInt(insert_chunk, 3, @intCast(idx));
            try bindText(insert_chunk, 4, chunk.content);
            if (chunk.embedding) |embedding| {
                try bindEmbeddingBlob(insert_chunk, 5, embedding);
                try bindInt(insert_chunk, 6, @intCast(embedding.len));
            } else {
                try bindNull(insert_chunk, 5);
                try bindInt(insert_chunk, 6, 0);
            }
            try stepDone(insert_chunk);

            const chunk_id = c.sqlite3_last_insert_rowid(self.handle);
            var chunk_id_buf: [32]u8 = undefined;
            const chunk_id_text = try std.fmt.bufPrint(chunk_id_buf[0..], "{d}", .{chunk_id});

            _ = c.sqlite3_reset(insert_fts);
            _ = c.sqlite3_clear_bindings(insert_fts);
            try bindText(insert_fts, 1, chunk.content);
            try bindText(insert_fts, 2, input.collection);
            try bindText(insert_fts, 3, input.path);
            try bindText(insert_fts, 4, chunk_id_text);
            try stepDone(insert_fts);
        }

        try self.exec("COMMIT;");
        committed = true;
    }

    pub fn lexicalSearchChunks(
        self: *Db,
        allocator: std.mem.Allocator,
        query_text: []const u8,
        collection: ?[]const u8,
        limit: usize,
    ) ![]LexicalChunkHit {
        if (limit == 0) return allocator.alloc(LexicalChunkHit, 0);

        const sql_filtered =
            \\SELECT
            \\  c.id, d.collection, d.path, c.content,
            \\  bm25(document_chunks_fts) AS bm
            \\FROM document_chunks_fts
            \\JOIN document_chunks c ON c.id = CAST(document_chunks_fts.chunk_id AS INTEGER)
            \\JOIN documents d ON d.id = c.document_id
            \\WHERE document_chunks_fts MATCH ?
            \\  AND d.active = 1
            \\  AND d.collection = ?
            \\ORDER BY bm ASC, c.id ASC
            \\LIMIT ?
        ;

        const sql_unfiltered =
            \\SELECT
            \\  c.id, d.collection, d.path, c.content,
            \\  bm25(document_chunks_fts) AS bm
            \\FROM document_chunks_fts
            \\JOIN document_chunks c ON c.id = CAST(document_chunks_fts.chunk_id AS INTEGER)
            \\JOIN documents d ON d.id = c.document_id
            \\WHERE document_chunks_fts MATCH ?
            \\  AND d.active = 1
            \\ORDER BY bm ASC, c.id ASC
            \\LIMIT ?
        ;

        const stmt = if (collection != null) try self.prepare(sql_filtered) else try self.prepare(sql_unfiltered);
        defer _ = c.sqlite3_finalize(stmt);

        try bindText(stmt, 1, query_text);
        if (collection) |wanted| {
            try bindText(stmt, 2, wanted);
            try bindInt(stmt, 3, @intCast(limit));
        } else {
            try bindInt(stmt, 2, @intCast(limit));
        }

        var rows = std.array_list.Managed(LexicalChunkHit).init(allocator);
        errdefer {
            for (rows.items) |row| row.deinit(allocator);
            rows.deinit();
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteFailure;

            const bm = c.sqlite3_column_double(stmt, 4);
            try rows.append(.{
                .chunk_id = c.sqlite3_column_int64(stmt, 0),
                .collection = try copyColumnText(allocator, stmt, 1),
                .path = try copyColumnText(allocator, stmt, 2),
                .content = try copyColumnText(allocator, stmt, 3),
                .bm25_score = bm,
                .lexical_score = bm25ToUnitScore(bm),
            });
        }

        return rows.toOwnedSlice();
    }

    pub fn vectorSearchChunksGlobal(
        self: *Db,
        allocator: std.mem.Allocator,
        query_embedding: []const f32,
        global_k: usize,
    ) ![]VectorChunkHit {
        if (global_k == 0 or query_embedding.len == 0) return allocator.alloc(VectorChunkHit, 0);

        const stmt = try self.prepare(
            \\SELECT c.id, d.collection, d.path, c.content, c.embedding, c.embedding_dim
            \\FROM document_chunks c
            \\JOIN documents d ON d.id = c.document_id
            \\WHERE d.active = 1
            \\  AND c.embedding IS NOT NULL
            \\  AND c.embedding_dim = ?
        );
        defer _ = c.sqlite3_finalize(stmt);

        try bindInt(stmt, 1, @intCast(query_embedding.len));

        var rows = std.array_list.Managed(VectorChunkHit).init(allocator);
        errdefer {
            for (rows.items) |row| row.deinit(allocator);
            rows.deinit();
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteFailure;

            const emb_raw = c.sqlite3_column_blob(stmt, 4);
            const emb_size: usize = @intCast(c.sqlite3_column_bytes(stmt, 4));
            const emb_dim: usize = @intCast(c.sqlite3_column_int64(stmt, 5));

            const distance = cosineDistanceFromBlob(query_embedding, emb_raw, emb_size, emb_dim) orelse continue;
            try rows.append(.{
                .chunk_id = c.sqlite3_column_int64(stmt, 0),
                .collection = try copyColumnText(allocator, stmt, 1),
                .path = try copyColumnText(allocator, stmt, 2),
                .content = try copyColumnText(allocator, stmt, 3),
                .distance = distance,
            });
        }

        std.sort.heap(VectorChunkHit, rows.items, {}, vectorHitLessThan);

        if (rows.items.len <= global_k) return rows.toOwnedSlice();

        var kept = std.array_list.Managed(VectorChunkHit).init(allocator);
        errdefer {
            for (kept.items) |row| row.deinit(allocator);
            kept.deinit();
        }
        try kept.appendSlice(rows.items[0..global_k]);
        for (rows.items[global_k..]) |row| row.deinit(allocator);
        rows.deinit();
        return kept.toOwnedSlice();
    }

    pub fn freeLexicalChunkHits(allocator: std.mem.Allocator, rows: []LexicalChunkHit) void {
        for (rows) |row| row.deinit(allocator);
        allocator.free(rows);
    }

    pub fn freeVectorChunkHits(allocator: std.mem.Allocator, rows: []VectorChunkHit) void {
        for (rows) |row| row.deinit(allocator);
        allocator.free(rows);
    }

    pub fn writeMemory(self: *Db, input: MemoryWriteInput) !void {
        if (input.confidence < 0.0 or input.confidence > 1.0) return error.InvalidScore;
        if (input.salience < 0.0 or input.salience > 1.0) return error.InvalidScore;

        try self.exec("BEGIN IMMEDIATE;");
        var committed = false;
        defer if (!committed) self.exec("ROLLBACK;") catch {};

        const supersedes = try self.currentEventId(input.memory_key);
        defer if (supersedes) |value| self.allocator.free(value);

        var event_id: [32]u8 = undefined;
        generateEventId(&event_id);

        const insert_event = try self.prepare(
            \\INSERT INTO memory_events(
            \\  event_id, memory_key, op, type, source, content,
            \\  confidence, salience, created_at, last_accessed_at, expires_at, supersedes
            \\) VALUES (?, ?, 'upsert', ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer _ = c.sqlite3_finalize(insert_event);

        try bindText(insert_event, 1, event_id[0..]);
        try bindText(insert_event, 2, input.memory_key);
        try bindText(insert_event, 3, input.mem_type);
        try bindText(insert_event, 4, input.source);
        try bindText(insert_event, 5, input.content);
        try bindDouble(insert_event, 6, input.confidence);
        try bindDouble(insert_event, 7, input.salience);
        try bindInt(insert_event, 8, input.now_ts);
        try bindInt(insert_event, 9, input.now_ts);
        try bindOptionalInt(insert_event, 10, input.expires_at);
        if (supersedes) |value| {
            try bindText(insert_event, 11, value);
        } else {
            try bindNull(insert_event, 11);
        }
        try stepDone(insert_event);

        const upsert = try self.prepare(
            \\INSERT INTO memories(
            \\  memory_key, current_event_id, type, source, content,
            \\  confidence, salience, created_at, last_accessed_at, expires_at, updated_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(memory_key) DO UPDATE SET
            \\  current_event_id = excluded.current_event_id,
            \\  type = excluded.type,
            \\  source = excluded.source,
            \\  content = excluded.content,
            \\  confidence = excluded.confidence,
            \\  salience = excluded.salience,
            \\  created_at = excluded.created_at,
            \\  last_accessed_at = excluded.last_accessed_at,
            \\  expires_at = excluded.expires_at,
            \\  updated_at = excluded.updated_at
        );
        defer _ = c.sqlite3_finalize(upsert);

        try bindText(upsert, 1, input.memory_key);
        try bindText(upsert, 2, event_id[0..]);
        try bindText(upsert, 3, input.mem_type);
        try bindText(upsert, 4, input.source);
        try bindText(upsert, 5, input.content);
        try bindDouble(upsert, 6, input.confidence);
        try bindDouble(upsert, 7, input.salience);
        try bindInt(upsert, 8, input.now_ts);
        try bindInt(upsert, 9, input.now_ts);
        try bindOptionalInt(upsert, 10, input.expires_at);
        try bindInt(upsert, 11, input.now_ts);
        try stepDone(upsert);

        try self.exec("COMMIT;");
        committed = true;
    }

    pub fn deleteMemory(self: *Db, memory_key: []const u8, source: []const u8, now_ts: i64) !void {
        try self.exec("BEGIN IMMEDIATE;");
        var committed = false;
        defer if (!committed) self.exec("ROLLBACK;") catch {};

        const supersedes = try self.currentEventId(memory_key);
        defer if (supersedes) |value| self.allocator.free(value);

        var event_id: [32]u8 = undefined;
        generateEventId(&event_id);

        const insert_event = try self.prepare(
            \\INSERT INTO memory_events(
            \\  event_id, memory_key, op, type, source, content,
            \\  confidence, salience, created_at, last_accessed_at, expires_at, supersedes
            \\) VALUES (?, ?, 'delete', 'tombstone', ?, '', 0.0, 0.0, ?, ?, NULL, ?)
        );
        defer _ = c.sqlite3_finalize(insert_event);

        try bindText(insert_event, 1, event_id[0..]);
        try bindText(insert_event, 2, memory_key);
        try bindText(insert_event, 3, source);
        try bindInt(insert_event, 4, now_ts);
        try bindInt(insert_event, 5, now_ts);
        if (supersedes) |value| {
            try bindText(insert_event, 6, value);
        } else {
            try bindNull(insert_event, 6);
        }
        try stepDone(insert_event);

        const delete_view = try self.prepare("DELETE FROM memories WHERE memory_key = ?;");
        defer _ = c.sqlite3_finalize(delete_view);
        try bindText(delete_view, 1, memory_key);
        try stepDone(delete_view);

        try self.exec("COMMIT;");
        committed = true;
    }

    pub fn touchMemory(self: *Db, memory_key: []const u8, source: []const u8, now_ts: i64) !void {
        const current = try self.currentMemory(memory_key) orelse return error.MemoryNotFound;
        defer current.deinit(self.allocator);

        try self.exec("BEGIN IMMEDIATE;");
        var committed = false;
        defer if (!committed) self.exec("ROLLBACK;") catch {};

        var event_id: [32]u8 = undefined;
        generateEventId(&event_id);

        const insert_event = try self.prepare(
            \\INSERT INTO memory_events(
            \\  event_id, memory_key, op, type, source, content,
            \\  confidence, salience, created_at, last_accessed_at, expires_at, supersedes
            \\) VALUES (?, ?, 'upsert', ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer _ = c.sqlite3_finalize(insert_event);

        try bindText(insert_event, 1, event_id[0..]);
        try bindText(insert_event, 2, memory_key);
        try bindText(insert_event, 3, current.mem_type);
        try bindText(insert_event, 4, source);
        try bindText(insert_event, 5, current.content);
        try bindDouble(insert_event, 6, current.confidence);
        try bindDouble(insert_event, 7, current.salience);
        try bindInt(insert_event, 8, current.created_at);
        try bindInt(insert_event, 9, now_ts);
        try bindOptionalInt(insert_event, 10, current.expires_at);
        try bindText(insert_event, 11, current.current_event_id);
        try stepDone(insert_event);

        const update_view = try self.prepare(
            \\UPDATE memories
            \\SET current_event_id = ?, source = ?, last_accessed_at = ?, updated_at = ?
            \\WHERE memory_key = ?
        );
        defer _ = c.sqlite3_finalize(update_view);
        try bindText(update_view, 1, event_id[0..]);
        try bindText(update_view, 2, source);
        try bindInt(update_view, 3, now_ts);
        try bindInt(update_view, 4, now_ts);
        try bindText(update_view, 5, memory_key);
        try stepDone(update_view);

        try self.exec("COMMIT;");
        committed = true;
    }

    pub fn listMemoriesRanked(
        self: *Db,
        allocator: std.mem.Allocator,
        now_ts: i64,
        limit: usize,
    ) ![]MemoryRow {
        const stmt = try self.prepare(
            \\SELECT
            \\  memory_key, type, source, content, confidence, salience,
            \\  created_at, last_accessed_at, expires_at,
            \\  (
            \\    (0.45 * salience) +
            \\    (0.35 * confidence) +
            \\    (0.20 * CASE
            \\      WHEN ? <= last_accessed_at THEN 1.0
            \\      ELSE (1.0 / (1.0 + ((? - last_accessed_at) / 86400.0)))
            \\    END)
            \\  ) AS rank_score
            \\FROM memories
            \\WHERE expires_at IS NULL OR expires_at > ?
            \\ORDER BY rank_score DESC, last_accessed_at DESC
            \\LIMIT ?
        );
        defer _ = c.sqlite3_finalize(stmt);

        try bindInt(stmt, 1, now_ts);
        try bindInt(stmt, 2, now_ts);
        try bindInt(stmt, 3, now_ts);
        try bindInt(stmt, 4, @intCast(limit));

        var rows = std.array_list.Managed(MemoryRow).init(allocator);
        errdefer {
            for (rows.items) |row| row.deinit(allocator);
            rows.deinit();
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteFailure;

            try rows.append(.{
                .memory_key = try copyColumnText(allocator, stmt, 0),
                .mem_type = try copyColumnText(allocator, stmt, 1),
                .source = try copyColumnText(allocator, stmt, 2),
                .content = try copyColumnText(allocator, stmt, 3),
                .confidence = c.sqlite3_column_double(stmt, 4),
                .salience = c.sqlite3_column_double(stmt, 5),
                .created_at = c.sqlite3_column_int64(stmt, 6),
                .last_accessed_at = c.sqlite3_column_int64(stmt, 7),
                .expires_at = if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 8),
                .rank_score = c.sqlite3_column_double(stmt, 9),
            });
        }

        return rows.toOwnedSlice();
    }

    pub fn freeMemoryRows(allocator: std.mem.Allocator, rows: []MemoryRow) void {
        for (rows) |row| row.deinit(allocator);
        allocator.free(rows);
    }

    pub fn countMemoryEvents(self: *Db, memory_key: []const u8) !usize {
        const stmt = try self.prepare("SELECT COUNT(*) FROM memory_events WHERE memory_key = ?;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, memory_key);
        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW) return error.SqliteFailure;
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    pub fn currentMemoryContent(self: *Db, allocator: std.mem.Allocator, memory_key: []const u8) !?[]u8 {
        const stmt = try self.prepare("SELECT content FROM memories WHERE memory_key = ? LIMIT 1;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, memory_key);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteFailure;
        return try copyColumnText(allocator, stmt, 0);
    }

    fn currentEventId(self: *Db, memory_key: []const u8) !?[]u8 {
        const stmt = try self.prepare("SELECT current_event_id FROM memories WHERE memory_key = ? LIMIT 1;");
        defer _ = c.sqlite3_finalize(stmt);

        try bindText(stmt, 1, memory_key);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteFailure;
        return try copyColumnText(self.allocator, stmt, 0);
    }

    fn currentMemory(self: *Db, memory_key: []const u8) !?CurrentMemory {
        const stmt = try self.prepare(
            \\SELECT current_event_id, type, content, confidence, salience, created_at, expires_at
            \\FROM memories
            \\WHERE memory_key = ?
            \\LIMIT 1
        );
        defer _ = c.sqlite3_finalize(stmt);

        try bindText(stmt, 1, memory_key);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteFailure;

        return .{
            .current_event_id = try copyColumnText(self.allocator, stmt, 0),
            .mem_type = try copyColumnText(self.allocator, stmt, 1),
            .content = try copyColumnText(self.allocator, stmt, 2),
            .confidence = c.sqlite3_column_double(stmt, 3),
            .salience = c.sqlite3_column_double(stmt, 4),
            .created_at = c.sqlite3_column_int64(stmt, 5),
            .expires_at = if (c.sqlite3_column_type(stmt, 6) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 6),
        };
    }

    fn documentId(self: *Db, collection: []const u8, path_key: []const u8) !?i64 {
        const stmt = try self.prepare(
            \\SELECT id
            \\FROM documents
            \\WHERE collection = ? AND path_key = ?
            \\LIMIT 1
        );
        defer _ = c.sqlite3_finalize(stmt);

        try bindText(stmt, 1, collection);
        try bindText(stmt, 2, path_key);

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteFailure;
        return c.sqlite3_column_int64(stmt, 0);
    }

    fn exec(self: *Db, sql: []const u8) !void {
        const zsql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(zsql);

        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, zsql.ptr, null, null, &err_msg);
        defer if (err_msg != null) c.sqlite3_free(err_msg);

        if (rc != c.SQLITE_OK) return error.SqliteFailure;
    }

    fn prepare(self: *Db, sql: []const u8) !*c.sqlite3_stmt {
        const zsql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(zsql);

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, zsql.ptr, -1, &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return error.SqliteFailure;
        return stmt.?;
    }
};

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) !void {
    const rc = c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), c.SQLITE_STATIC);
    if (rc != c.SQLITE_OK) return error.SqliteFailure;
}

fn bindDouble(stmt: *c.sqlite3_stmt, index: c_int, value: f64) !void {
    const rc = c.sqlite3_bind_double(stmt, index, value);
    if (rc != c.SQLITE_OK) return error.SqliteFailure;
}

fn bindInt(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    const rc = c.sqlite3_bind_int64(stmt, index, value);
    if (rc != c.SQLITE_OK) return error.SqliteFailure;
}

fn bindOptionalInt(stmt: *c.sqlite3_stmt, index: c_int, value: ?i64) !void {
    if (value) |int_value| return bindInt(stmt, index, int_value);
    return bindNull(stmt, index);
}

fn bindNull(stmt: *c.sqlite3_stmt, index: c_int) !void {
    const rc = c.sqlite3_bind_null(stmt, index);
    if (rc != c.SQLITE_OK) return error.SqliteFailure;
}

fn bindEmbeddingBlob(stmt: *c.sqlite3_stmt, index: c_int, embedding: []const f32) !void {
    const bytes = std.mem.sliceAsBytes(embedding);
    const rc = c.sqlite3_bind_blob(stmt, index, bytes.ptr, @intCast(bytes.len), c.SQLITE_STATIC);
    if (rc != c.SQLITE_OK) return error.SqliteFailure;
}

fn stepDone(stmt: *c.sqlite3_stmt) !void {
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) return error.SqliteFailure;
}

fn copyColumnText(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, column: c_int) ![]u8 {
    const raw = c.sqlite3_column_text(stmt, column);
    if (raw == null) return allocator.dupe(u8, "");
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    const slice = @as([*]const u8, @ptrCast(raw))[0..len];
    return allocator.dupe(u8, slice);
}

fn generateEventId(buf: *[32]u8) void {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    buf.* = std.fmt.bytesToHex(bytes, .lower);
}

fn bm25ToUnitScore(value: f64) f64 {
    return 1.0 / (1.0 + @abs(value));
}

fn cosineDistanceFromBlob(
    query: []const f32,
    blob_ptr: ?*const anyopaque,
    blob_size: usize,
    blob_dim: usize,
) ?f64 {
    if (blob_ptr == null) return null;
    if (blob_dim == 0 or blob_dim != query.len) return null;
    if (blob_size != blob_dim * @sizeOf(f32)) return null;

    const raw_bytes = @as([*]const u8, @ptrCast(blob_ptr.?))[0..blob_size];
    const emb = std.mem.bytesAsSlice(f32, raw_bytes);

    var dot: f64 = 0.0;
    var q_norm_sq: f64 = 0.0;
    var emb_norm_sq: f64 = 0.0;

    for (query, emb) |q, e| {
        const q64 = @as(f64, q);
        const e64 = @as(f64, e);
        dot += q64 * e64;
        q_norm_sq += q64 * q64;
        emb_norm_sq += e64 * e64;
    }

    if (q_norm_sq == 0.0 or emb_norm_sq == 0.0) return null;
    const cosine = dot / (std.math.sqrt(q_norm_sq) * std.math.sqrt(emb_norm_sq));
    const clamped = std.math.clamp(cosine, -1.0, 1.0);
    return 1.0 - clamped;
}

fn vectorHitLessThan(_: void, a: VectorChunkHit, b: VectorChunkHit) bool {
    if (a.distance == b.distance) return a.chunk_id < b.chunk_id;
    return a.distance < b.distance;
}

test "write memory keeps append-only history and updates current view" {
    const alloc = std.testing.allocator;

    var db = try Db.open(alloc, ":memory:");
    defer db.close();
    try db.initSchema();

    try db.writeMemory(.{
        .memory_key = "user:name",
        .mem_type = "profile",
        .source = "manual",
        .content = "Alice",
        .confidence = 0.9,
        .salience = 0.8,
        .now_ts = 1000,
    });
    try db.writeMemory(.{
        .memory_key = "user:name",
        .mem_type = "profile",
        .source = "manual",
        .content = "Alice Johnson",
        .confidence = 0.95,
        .salience = 0.85,
        .now_ts = 2000,
    });

    const event_count = try db.countMemoryEvents("user:name");
    try std.testing.expectEqual(@as(usize, 2), event_count);

    const content = (try db.currentMemoryContent(alloc, "user:name")) orelse return error.TestUnexpectedResult;
    defer alloc.free(content);
    try std.testing.expectEqualStrings("Alice Johnson", content);
}

test "delete memory appends tombstone and removes current record" {
    const alloc = std.testing.allocator;

    var db = try Db.open(alloc, ":memory:");
    defer db.close();
    try db.initSchema();

    try db.writeMemory(.{
        .memory_key = "project:status",
        .mem_type = "fact",
        .source = "note",
        .content = "active",
        .confidence = 0.7,
        .salience = 0.6,
        .now_ts = 500,
    });
    try db.deleteMemory("project:status", "note", 700);

    const event_count = try db.countMemoryEvents("project:status");
    try std.testing.expectEqual(@as(usize, 2), event_count);

    const content = try db.currentMemoryContent(alloc, "project:status");
    try std.testing.expect(content == null);
}

test "ranking blends salience confidence and recency" {
    const alloc = std.testing.allocator;

    var db = try Db.open(alloc, ":memory:");
    defer db.close();
    try db.initSchema();

    try db.writeMemory(.{
        .memory_key = "a",
        .mem_type = "fact",
        .source = "seed",
        .content = "old but important",
        .confidence = 0.9,
        .salience = 1.0,
        .now_ts = 100,
    });
    try db.writeMemory(.{
        .memory_key = "b",
        .mem_type = "fact",
        .source = "seed",
        .content = "fresh medium",
        .confidence = 0.6,
        .salience = 0.6,
        .now_ts = 5000,
    });

    const rows = try db.listMemoriesRanked(alloc, 5100, 10);
    defer Db.freeMemoryRows(alloc, rows);

    try std.testing.expect(rows.len >= 2);
    try std.testing.expect(rows[0].rank_score >= rows[1].rank_score);
}

test "document chunks support both lexical and vector retrieval" {
    const alloc = std.testing.allocator;

    var db = try Db.open(alloc, ":memory:");
    defer db.close();
    try db.initSchema();

    const chunks = [_]DocumentChunkInput{
        .{ .content = "SQLite FTS5 hybrid retrieval", .embedding = &[_]f32{ 1.0, 0.0 } },
        .{ .content = "Long-term assistant memory", .embedding = &[_]f32{ 0.0, 1.0 } },
    };

    try db.upsertDocument(.{
        .collection = "work",
        .path = "notes/architecture.md",
        .path_key = "notes/architecture.md",
        .path_search = "notes/architecture.md",
        .hash = "h1",
        .modified_at = 100,
        .chunks = &chunks,
    });

    const lexical = try db.lexicalSearchChunks(alloc, "FTS5 hybrid", null, 5);
    defer Db.freeLexicalChunkHits(alloc, lexical);
    try std.testing.expect(lexical.len >= 1);

    const vector_hits = try db.vectorSearchChunksGlobal(alloc, &[_]f32{ 1.0, 0.0 }, 5);
    defer Db.freeVectorChunkHits(alloc, vector_hits);
    try std.testing.expect(vector_hits.len >= 1);
    try std.testing.expect(vector_hits[0].distance <= vector_hits[vector_hits.len - 1].distance);
}
