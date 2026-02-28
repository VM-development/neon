const std = @import("std");

pub const Document = struct {
    file: []const u8,
    body: []const u8,
};

pub const ChunkCandidate = struct {
    file: []const u8,
    doc_index: usize,
    chunk_index: usize,
    text: []const u8,
    lexical_overlap: usize,
};

pub const ChunkScore = struct {
    candidate_index: usize,
    score: f64,
};

pub const DocumentScore = struct {
    file: []const u8,
    doc_index: usize,
    best_chunk: []const u8,
    score: f64,
};

pub fn extractQueryTerms(allocator: std.mem.Allocator, query: []const u8) ![]const []const u8 {
    const lower = try allocator.dupe(u8, query);
    defer allocator.free(lower);
    _ = std.ascii.lowerString(lower, lower);

    var terms = std.array_list.Managed([]const u8).init(allocator);
    var it = std.mem.tokenizeAny(u8, lower, " \t\r\n");
    while (it.next()) |term| {
        if (term.len >= 3) {
            try terms.append(try allocator.dupe(u8, term));
        }
    }
    return terms.toOwnedSlice();
}

pub fn freeTerms(allocator: std.mem.Allocator, terms: []const []const u8) void {
    for (terms) |term| allocator.free(term);
    allocator.free(terms);
}

pub fn selectTopChunksPerDoc(
    allocator: std.mem.Allocator,
    docs: []const Document,
    query_terms: []const []const u8,
    per_doc: usize,
) ![]ChunkCandidate {
    var selected = std.array_list.Managed(ChunkCandidate).init(allocator);
    errdefer selected.deinit();

    for (docs, 0..) |doc, doc_idx| {
        var local = std.array_list.Managed(ChunkCandidate).init(allocator);
        defer local.deinit();

        var chunk_it = std.mem.splitSequence(u8, doc.body, "\n\n");
        var chunk_index: usize = 0;
        while (chunk_it.next()) |chunk_raw| : (chunk_index += 1) {
            const chunk = std.mem.trim(u8, chunk_raw, " \t\r\n");
            if (chunk.len == 0) continue;

            try local.append(.{
                .file = doc.file,
                .doc_index = doc_idx,
                .chunk_index = chunk_index,
                .text = chunk,
                .lexical_overlap = lexicalOverlap(chunk, query_terms),
            });
        }
        if (local.items.len == 0) continue;

        std.sort.heap(ChunkCandidate, local.items, {}, chunkLessThan);

        const take = @min(per_doc, local.items.len);
        for (local.items[0..take]) |item| {
            try selected.append(item);
        }
    }

    return selected.toOwnedSlice();
}

pub fn aggregateDocumentScores(
    allocator: std.mem.Allocator,
    candidates: []const ChunkCandidate,
    scored_chunks: []const ChunkScore,
) ![]DocumentScore {
    var by_file = std.StringHashMap(DocumentScore).init(allocator);
    defer by_file.deinit();

    for (scored_chunks) |scored| {
        if (scored.candidate_index >= candidates.len) continue;
        const cand = candidates[scored.candidate_index];

        const existing = by_file.get(cand.file);
        if (existing == null or scored.score > existing.?.score) {
            try by_file.put(cand.file, .{
                .file = cand.file,
                .doc_index = cand.doc_index,
                .best_chunk = cand.text,
                .score = scored.score,
            });
        }
    }

    var rows = std.array_list.Managed(DocumentScore).init(allocator);
    errdefer rows.deinit();

    var it = by_file.iterator();
    while (it.next()) |entry| {
        try rows.append(entry.value_ptr.*);
    }

    std.sort.heap(DocumentScore, rows.items, {}, docScoreLessThan);
    return rows.toOwnedSlice();
}

fn lexicalOverlap(chunk: []const u8, query_terms: []const []const u8) usize {
    var overlap: usize = 0;
    for (query_terms) |term| {
        if (containsIgnoreCase(chunk, term)) overlap += 1;
    }
    return overlap;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn chunkLessThan(_: void, a: ChunkCandidate, b: ChunkCandidate) bool {
    if (a.lexical_overlap == b.lexical_overlap) {
        return a.chunk_index < b.chunk_index;
    }
    return a.lexical_overlap > b.lexical_overlap;
}

fn docScoreLessThan(_: void, a: DocumentScore, b: DocumentScore) bool {
    if (a.score == b.score) return a.doc_index < b.doc_index;
    return a.score > b.score;
}

test "rerank aggregation keeps files separate when chunk text is identical" {
    const alloc = std.testing.allocator;
    const docs = [_]Document{
        .{ .file = "a.md", .body = "shared chunk\n\nother" },
        .{ .file = "b.md", .body = "shared chunk\n\nanother" },
    };
    const terms = try extractQueryTerms(alloc, "shared chunk");
    defer freeTerms(alloc, terms);

    const candidates = try selectTopChunksPerDoc(alloc, &docs, terms, 1);
    defer alloc.free(candidates);

    const scored = [_]ChunkScore{
        .{ .candidate_index = 0, .score = 0.2 },
        .{ .candidate_index = 1, .score = 0.9 },
    };
    const per_doc = try aggregateDocumentScores(alloc, candidates, &scored);
    defer alloc.free(per_doc);

    try std.testing.expectEqual(@as(usize, 2), per_doc.len);
    try std.testing.expectEqualStrings("b.md", per_doc[0].file);
    try std.testing.expectEqualStrings("a.md", per_doc[1].file);
}

test "top-n chunk selection can select more than one chunk per document" {
    const alloc = std.testing.allocator;
    const docs = [_]Document{
        .{
            .file = "memory.md",
            .body =
            \\rate limit handling details
            \\
            \\unrelated appendix
            \\
            \\rate limit retry windows and backoff
            ,
        },
    };
    const terms = try extractQueryTerms(alloc, "rate limit retry");
    defer freeTerms(alloc, terms);

    const candidates = try selectTopChunksPerDoc(alloc, &docs, terms, 2);
    defer alloc.free(candidates);

    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expect(candidates[0].lexical_overlap >= candidates[1].lexical_overlap);
}
