// example/src/main.zig
//
// End-to-end demonstration of the neon API.
//
// Sections (run in order):
//   1. Engine lifecycle        — open / close an in-memory database
//   2. Key-value memory        — writeMemory, getMemoryContent, listMemoriesRanked,
//                                touchMemory, deleteMemory
//   3. Document indexing       — upsertDocument (single + multi-chunk, with / without
//                                embeddings)
//   4. Lexical search          — hybridQuery (text-only, no embedding)
//   5. Hybrid search           — hybridQuery with query_embedding
//   6. Collection filtering    — narrowing results to a specific collection
//   7. Memory expiry           — expires_at, confirmed by ranked recall
//   8. Revision history        — multiple writes to the same key accumulate events
//   9. Document re-index       — upsertDocument is idempotent; re-inserting replaces
//                                chunks
//
// All heap memory is freed correctly — run with a GeneralPurposeAllocator so
// leaks are caught automatically.

const std = @import("std");
const neon = @import("neon");

// Helpers ─────────────────────────────────────────────────────────────────────

fn sep(comptime label: []const u8) void {
    std.debug.print("\n─── {s} {s}\n", .{ label, "─" ** (60 - label.len - 1) });
}

fn ok(comptime msg: []const u8) void {
    std.debug.print("  [ok] " ++ msg ++ "\n", .{});
}

fn okFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("  [ok] " ++ fmt ++ "\n", args);
}

// ─────────────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak = gpa.deinit();
        if (leak == .leak) std.debug.print("\n[WARN] memory leak detected!\n", .{});
    }
    const allocator = gpa.allocator();

    // ── 1. Engine lifecycle ───────────────────────────────────────────────────
    sep("1. Engine lifecycle");

    // ":memory:" uses an in-process SQLite database — nothing is written to disk.
    // For a real app, pass a file path such as "~/.aeon/memory.sqlite".
    var engine = try neon.api.Engine.open(allocator, ":memory:");
    defer engine.close();
    ok("Engine.open(\":memory:\") — schema initialised");

    // ── 2. Key-value memory ───────────────────────────────────────────────────
    sep("2. Key-value memory");

    // writeMemory — create or update a fact.
    // The key is namespaced by convention: "scope:attribute".
    try engine.writeMemory(.{
        .memory_key = "user:name",
        .mem_type = "profile",
        .source = "manual",
        .content = "Alice Johnson",
        .confidence = 0.99,
        .salience = 0.90,
    });
    ok("writeMemory: user:name = \"Alice Johnson\"");

    try engine.writeMemory(.{
        .memory_key = "user:location",
        .mem_type = "profile",
        .source = "inference",
        .content = "Berlin, Germany",
        .confidence = 0.75,
        .salience = 0.70,
    });
    ok("writeMemory: user:location = \"Berlin, Germany\"");

    try engine.writeMemory(.{
        .memory_key = "user:pref:language",
        .mem_type = "preference",
        .source = "inference",
        .content = "English",
        .confidence = 0.85,
        .salience = 0.60,
    });
    ok("writeMemory: user:pref:language = \"English\"");

    try engine.writeMemory(.{
        .memory_key = "user:pref:theme",
        .mem_type = "preference",
        .source = "manual",
        .content = "dark",
        .confidence = 1.00,
        .salience = 0.40,
    });
    ok("writeMemory: user:pref:theme = \"dark\"");

    // getMemoryContent — quick single-key lookup (no ranking).
    {
        const name = try engine.getMemoryContent("user:name");
        defer if (name) |s| allocator.free(s);
        std.debug.print("  [ok] getMemoryContent(\"user:name\") = \"{s}\"\n", .{name orelse "(nil)"});
    }
    {
        // A key that does not exist returns null.
        const missing = try engine.getMemoryContent("user:email");
        defer if (missing) |s| allocator.free(s);
        std.debug.print("  [ok] getMemoryContent(\"user:email\") = {s}\n", .{if (missing == null) "null (expected)" else "unexpected value!"});
    }

    // listMemoriesRanked — returns entries sorted by
    //   rank = 0.45*salience + 0.35*confidence + 0.20*recency_decay
    {
        const rows = try engine.listMemoriesRanked(10);
        defer neon.api.freeMemoryRows(allocator, rows);

        std.debug.print("  [ok] listMemoriesRanked(10) → {d} rows:\n", .{rows.len});
        for (rows, 1..) |row, i| {
            std.debug.print("       {d}. [{s}] \"{s}\" = \"{s}\"  rank={d:.3}\n", .{
                i, row.mem_type, row.memory_key, row.content, row.rank_score,
            });
        }
    }

    // touchMemory — reinforce a memory's recency without changing its content.
    try engine.touchMemory("user:location", "access");
    ok("touchMemory: user:location — last_accessed_at updated");

    // writeMemory again — supersedes the previous revision, creating a new event.
    try engine.writeMemory(.{
        .memory_key = "user:location",
        .mem_type = "profile",
        .source = "manual",
        .content = "Hamburg, Germany",
        .confidence = 0.98,
        .salience = 0.72,
    });
    ok("writeMemory: user:location updated to \"Hamburg, Germany\"");

    {
        const loc = try engine.getMemoryContent("user:location");
        defer if (loc) |s| allocator.free(s);
        std.debug.print("  [ok] getMemoryContent(\"user:location\") = \"{s}\" (updated)\n", .{loc orelse "(nil)"});
    }

    // deleteMemory — tombstones the entry; it no longer appears in ranked recall.
    try engine.deleteMemory("user:pref:theme", "manual");
    ok("deleteMemory: user:pref:theme tombstoned");

    {
        const rows = try engine.listMemoriesRanked(10);
        defer neon.api.freeMemoryRows(allocator, rows);
        std.debug.print("  [ok] listMemoriesRanked after delete → {d} rows (theme gone):\n", .{rows.len});
        for (rows) |row| {
            std.debug.print("       \"{s}\" = \"{s}\"\n", .{ row.memory_key, row.content });
        }
    }

    // ── 3. Document indexing ──────────────────────────────────────────────────
    sep("3. Document indexing");

    // A document is a logical unit (file, note, conversation summary …) that
    // is split into one or more chunks.  Each chunk can carry an optional
    // float32 embedding for vector search.

    // Single-chunk document, no embedding (lexical search only).
    try engine.upsertDocument(.{
        .collection = "notes",
        .path = "notes/onboarding.md",
        .hash = "abc123",
        .modified_at = std.time.timestamp(),
        .chunks = &.{
            .{ .content = "Welcome to Aeon. This assistant remembers your preferences across sessions." },
        },
    });
    ok("upsertDocument: notes/onboarding.md (1 chunk, no embedding)");

    // Multi-chunk document, each chunk has a 3-dimensional embedding.
    const arch_chunks = [_]neon.api.ChunkInput{
        .{
            .content = "Neon uses SQLite FTS5 for lexical full-text search.",
            .embedding = &[_]f32{ 0.80, 0.15, 0.05 },
        },
        .{
            .content = "Vector search runs cosine distance over f32 BLOBs stored in document_chunks.",
            .embedding = &[_]f32{ 0.60, 0.30, 0.10 },
        },
        .{
            .content = "Hybrid fusion combines BM25 and cosine scores with configurable weights.",
            .embedding = &[_]f32{ 0.50, 0.40, 0.10 },
        },
    };
    try engine.upsertDocument(.{
        .collection = "work",
        .path = "work/architecture.md",
        .hash = "def456",
        .modified_at = std.time.timestamp(),
        .chunks = &arch_chunks,
    });
    ok("upsertDocument: work/architecture.md (3 chunks, with embeddings)");

    // Another document in a different collection.
    const diary_chunks = [_]neon.api.ChunkInput{
        .{
            .content = "Today I learned about persistent memory for AI assistants.",
            .embedding = &[_]f32{ 0.20, 0.70, 0.10 },
        },
        .{
            .content = "The key insight is separating episodic facts from semantic knowledge.",
            .embedding = &[_]f32{ 0.10, 0.65, 0.25 },
        },
    };
    try engine.upsertDocument(.{
        .collection = "diary",
        .path = "diary/2025-02-28.md",
        .hash = "ghi789",
        .modified_at = std.time.timestamp(),
        .chunks = &diary_chunks,
    });
    ok("upsertDocument: diary/2025-02-28.md (2 chunks, with embeddings)");

    // ── 4. Lexical search ─────────────────────────────────────────────────────
    sep("4. Lexical search (no embedding)");

    {
        // query_embedding = null  →  only BM25 scoring is used.
        const hits = try engine.hybridQuery(.{
            .query_text = "lexical search FTS5",
            .limit = 5,
        });
        defer neon.api.freeSearchHits(allocator, hits);

        std.debug.print("  [ok] hybridQuery(\"lexical search FTS5\", limit=5) → {d} hits:\n", .{hits.len});
        for (hits, 1..) |h, i| {
            std.debug.print(
                "       {d}. [{s}] {s}  lex={d:.3} vec={d:.3} fused={d:.3}\n",
                .{ i, h.collection, h.path, h.lexical_score, h.vector_score, h.fused_score },
            );
        }
    }

    // ── 5. Hybrid search ──────────────────────────────────────────────────────
    sep("5. Hybrid search (lexical + vector)");

    {
        // Provide a query embedding to enable vector scoring.
        // The fused score blends both signals (default: 45% lexical + 55% vector).
        const hits = try engine.hybridQuery(.{
            .query_text = "cosine distance memory",
            .query_embedding = &[_]f32{ 0.65, 0.25, 0.10 },
            .limit = 5,
        });
        defer neon.api.freeSearchHits(allocator, hits);

        std.debug.print(
            "  [ok] hybridQuery(\"cosine distance memory\", embedding=[0.65,0.25,0.10], limit=5) → {d} hits:\n",
            .{hits.len},
        );
        for (hits, 1..) |h, i| {
            std.debug.print(
                "       {d}. [{s}] {s}  lex={d:.3} vec={d:.3} fused={d:.3}\n",
                .{ i, h.collection, h.path, h.lexical_score, h.vector_score, h.fused_score },
            );
            std.debug.print("          \"{s}\"\n", .{h.content});
        }
    }

    // Custom weight: lexical-heavy (80/20 split).
    {
        const hits = try engine.hybridQuery(.{
            .query_text = "persistent memory AI assistant",
            .query_embedding = &[_]f32{ 0.25, 0.65, 0.10 },
            .limit = 5,
            .lexical_weight = 0.80,
            .vector_weight = 0.20,
        });
        defer neon.api.freeSearchHits(allocator, hits);

        std.debug.print(
            "  [ok] hybridQuery with lexical_weight=0.80 → {d} hits:\n",
            .{hits.len},
        );
        for (hits, 1..) |h, i| {
            std.debug.print(
                "       {d}. [{s}] {s}  fused={d:.3}\n",
                .{ i, h.collection, h.path, h.fused_score },
            );
        }
    }

    // ── 6. Collection filtering ───────────────────────────────────────────────
    sep("6. Collection filtering");

    {
        // Restrict results to the "diary" collection only.
        const hits = try engine.hybridQuery(.{
            .query_text = "memory assistant",
            .query_embedding = &[_]f32{ 0.20, 0.70, 0.10 },
            .collection = "diary",
            .limit = 5,
        });
        defer neon.api.freeSearchHits(allocator, hits);

        std.debug.print(
            "  [ok] hybridQuery(collection=\"diary\") → {d} hits (all should be diary):\n",
            .{hits.len},
        );
        for (hits, 1..) |h, i| {
            std.debug.print("       {d}. [{s}] {s}\n", .{ i, h.collection, h.path });
        }

        // Verify — all hits must belong to "diary".
        for (hits) |h| {
            std.debug.assert(std.mem.eql(u8, h.collection, "diary"));
        }
        ok("collection constraint verified");
    }

    // ── 7. Memory expiry ─────────────────────────────────────────────────────
    sep("7. Memory expiry");

    // Write a memory that expires in the past — it should not appear in recall.
    const past_ts: i64 = std.time.timestamp() - 3600; // 1 hour ago
    try engine.writeMemory(.{
        .memory_key = "session:last_topic",
        .mem_type = "session",
        .source = "inference",
        .content = "Zig build systems",
        .confidence = 0.80,
        .salience = 0.50,
        .expires_at = past_ts,
    });
    ok("writeMemory: session:last_topic with expires_at = now - 1h");

    {
        const rows = try engine.listMemoriesRanked(20);
        defer neon.api.freeMemoryRows(allocator, rows);

        var found = false;
        for (rows) |row| {
            if (std.mem.eql(u8, row.memory_key, "session:last_topic")) {
                found = true;
            }
        }
        std.debug.print(
            "  [ok] expired entry present in ranked list: {s} (expected: false)\n",
            .{if (found) "true" else "false"},
        );
        std.debug.assert(!found);
    }

    // Write a memory that expires far in the future — it should appear.
    const future_ts: i64 = std.time.timestamp() + 86400 * 365; // 1 year
    try engine.writeMemory(.{
        .memory_key = "session:next_reminder",
        .mem_type = "session",
        .source = "manual",
        .content = "Review architecture notes",
        .confidence = 0.90,
        .salience = 0.65,
        .expires_at = future_ts,
    });
    ok("writeMemory: session:next_reminder with expires_at = now + 1y");

    {
        const content = try engine.getMemoryContent("session:next_reminder");
        defer if (content) |s| allocator.free(s);
        std.debug.print(
            "  [ok] getMemoryContent(\"session:next_reminder\") = \"{s}\"\n",
            .{content orelse "(nil)"},
        );
        std.debug.assert(content != null);
    }

    // ── 8. Revision history ───────────────────────────────────────────────────
    sep("8. Revision history");

    // Every writeMemory call appends to the append-only memory_events log.
    // We can verify this by looking at the db directly (via countMemoryEvents).
    {
        // We've written "user:location" three times (initial + touch + update).
        // writeMemory × 2 + touchMemory × 1 = 3 events.
        const count = try engine.db.countMemoryEvents("user:location");
        std.debug.print(
            "  [ok] countMemoryEvents(\"user:location\") = {d} (expected ≥ 3)\n",
            .{count},
        );
        std.debug.assert(count >= 3);
    }

    {
        // deleteMemory also writes an event (op='delete') but removes the row
        // from the materialized `memories` view.
        const count = try engine.db.countMemoryEvents("user:pref:theme");
        std.debug.print(
            "  [ok] countMemoryEvents(\"user:pref:theme\") = {d} (delete event present)\n",
            .{count},
        );
        std.debug.assert(count >= 2); // write + delete
    }

    // ── 9. Document re-index (idempotent upsert) ──────────────────────────────
    sep("9. Document re-index");

    // Upserting the same (collection, path) pair replaces the old chunks.
    // The hash should change when content changes; here we simulate an edit.
    try engine.upsertDocument(.{
        .collection = "work",
        .path = "work/architecture.md",
        .hash = "def456-v2", // new hash signals updated content
        .modified_at = std.time.timestamp(),
        .chunks = &.{
            .{
                .content = "Neon uses SQLite FTS5 for lexical search and cosine distance for vectors.",
                .embedding = &[_]f32{ 0.75, 0.20, 0.05 },
            },
            .{
                .content = "The hybrid fusion formula: fused = lex_w * bm25_score + vec_w * cosine_score.",
                .embedding = &[_]f32{ 0.55, 0.35, 0.10 },
            },
        },
    });
    ok("upsertDocument: work/architecture.md re-indexed with updated content (2 chunks now)");

    {
        // The old 3-chunk content is gone; searching returns the new chunks.
        const hits = try engine.hybridQuery(.{
            .query_text = "FTS5 cosine hybrid fusion",
            .query_embedding = &[_]f32{ 0.70, 0.20, 0.10 },
            .collection = "work",
            .limit = 5,
        });
        defer neon.api.freeSearchHits(allocator, hits);

        std.debug.print("  [ok] after re-index, work collection has {d} hits:\n", .{hits.len});
        for (hits, 1..) |h, i| {
            std.debug.print("       {d}. fused={d:.3}  \"{s}\"\n", .{ i, h.fused_score, h.content });
        }
    }

    // ── Done ──────────────────────────────────────────────────────────────────
    sep("Done");
    std.debug.print("  All sections completed successfully.\n\n", .{});
}
