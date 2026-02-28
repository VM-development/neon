# neon

Long-term AI assistant memory system.

## Implemented in this first slice

- SQLite schema with:
  - `memory_events` append-only log
  - `memories` current materialized view
  - fields for `type`, `source`, `confidence`, `salience`, `created_at`, `last_accessed_at`, `supersedes`, `expires_at`
- Hybrid retrieval schema with:
  - `documents` metadata table
  - `document_chunks` table storing chunk text + embedding blobs
  - `document_chunks_fts` (SQLite FTS5) for lexical retrieval
- Write/update/delete/touch memory operations with revision history retention.
- Recency + salience + confidence ranking for memory listing.
- Hybrid lexical + vector retrieval with adaptive collection filtering at query time.
- Correctness modules with tests for:
  - duplicate-text-safe rerank mapping
  - strict path identity (`path_key`) to avoid case/punctuation overwrite collisions
  - unambiguous docid prefix resolution states (`found` / `ambiguous` / `not_found`)
  - context prefix segment-boundary matching
  - vector distance score normalization to consistent `0..1`
  - adaptive vector collection filtering strategy (`k` growth by attempts)
- MCP tool descriptor registry includes write-capable memory tools.

## Build and test

```bash
zig build test
zig build
```

## CLI

```bash
zig build run -- init ./memory.sqlite
zig build run -- memory-put ./memory.sqlite user:name profile manual 0.95 0.90 "Alice Johnson"
zig build run -- memory-touch ./memory.sqlite user:name access
zig build run -- memory-list ./memory.sqlite 20
zig build run -- memory-delete ./memory.sqlite user:name manual

# Index one chunk (optional embedding CSV for vector retrieval)
zig build run -- doc-put ./memory.sqlite work notes/architecture.md h1 "SQLite FTS5 + vector backend" "0.10,0.25,0.65"

# Hybrid query: lexical only
zig build run -- query ./memory.sqlite "vector backend" 5

# Hybrid query: lexical + vector + collection filter (use '-' for no filter)
zig build run -- query ./memory.sqlite "assistant memory" 5 work "0.10,0.25,0.65"

zig build run -- mcp-tools
```

## Zig API

Use `src/api.zig` when embedding in another Zig app.

```zig
const std = @import("std");
const neon = @import("lib.zig");

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer _ = gpa.deinit();
  const allocator = gpa.allocator();

  var engine = try neon.api.Engine.open(allocator, "./memory.sqlite");
  defer engine.close();

  const chunks = [_]neon.api.ChunkInput{
    .{ .content = "Long-term memory retrieval", .embedding = &[_]f32{ 0.4, 0.2, 0.8 } },
  };
  try engine.upsertDocument(.{
    .collection = "work",
    .path = "notes/memory.md",
    .hash = "dochash",
    .modified_at = std.time.timestamp(),
    .chunks = &chunks,
  });

  const hits = try engine.hybridQuery(.{
    .query_text = "memory retrieval",
    .query_embedding = &[_]f32{ 0.4, 0.2, 0.8 },
    .collection = "work",
    .limit = 5,
  });
  defer neon.api.freeSearchHits(allocator, hits);
}
```

### Retrieval behavior

- Lexical: SQLite `FTS5` (`document_chunks_fts MATCH ...`) with BM25 normalization to `0..1`.
- Vector: cosine distance over embedding blobs in `document_chunks`.
- Collection filter: vector stage runs adaptive global-k widening before applying collection constraint.
- Fusion: weighted score combining lexical and vector unit scores.

## Notes

Reranker model calls and MCP transport wiring are still pending future slices.
