const std = @import("std");
const Io = std.Io;
const db_mod = @import("db.zig");
const mcp_tools = @import("mcp_tools.zig");
const api_mod = @import("api.zig");

/// Get current Unix epoch timestamp in seconds.
/// Replaces std.time.timestamp() which was removed in 0.16.
fn currentUnixSeconds(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len < 2) {
        usage();
        return;
    }

    const cmd = argv[1];
    if (std.mem.eql(u8, cmd, "init")) {
        if (argv.len != 3) return usage();
        try runInit(allocator, io, argv[2]);
        return;
    }
    if (std.mem.eql(u8, cmd, "memory-put")) {
        if (argv.len < 9 or argv.len > 10) return usage();
        try runMemoryPut(allocator, io, argv);
        return;
    }
    if (std.mem.eql(u8, cmd, "memory-delete")) {
        if (argv.len != 5) return usage();
        try runMemoryDelete(allocator, io, argv[2], argv[3], argv[4]);
        return;
    }
    if (std.mem.eql(u8, cmd, "memory-touch")) {
        if (argv.len != 5) return usage();
        try runMemoryTouch(allocator, io, argv[2], argv[3], argv[4]);
        return;
    }
    if (std.mem.eql(u8, cmd, "memory-list")) {
        if (argv.len < 3 or argv.len > 4) return usage();
        const limit: usize = if (argv.len == 4) try std.fmt.parseUnsigned(usize, argv[3], 10) else 20;
        try runMemoryList(allocator, io, argv[2], limit);
        return;
    }
    if (std.mem.eql(u8, cmd, "doc-put")) {
        if (argv.len < 7 or argv.len > 8) return usage();
        try runDocPut(allocator, io, argv);
        return;
    }
    if (std.mem.eql(u8, cmd, "query")) {
        if (argv.len < 5 or argv.len > 7) return usage();
        try runQuery(allocator, io, argv);
        return;
    }
    if (std.mem.eql(u8, cmd, "mcp-tools")) {
        try runMcpTools();
        return;
    }

    usage();
}

fn runInit(allocator: std.mem.Allocator, io: Io, db_path: []const u8) !void {
    var db = try db_mod.Db.open(allocator, io, db_path);
    defer db.close();
    try db.initSchema();
    std.debug.print("initialized schema at {s}\n", .{db_path});
}

fn runMemoryPut(allocator: std.mem.Allocator, io: Io, argv: []const []const u8) !void {
    const db_path = argv[2];
    const memory_key = argv[3];
    const mem_type = argv[4];
    const source = argv[5];
    const confidence = try std.fmt.parseFloat(f64, argv[6]);
    const salience = try std.fmt.parseFloat(f64, argv[7]);
    const content = argv[8];
    const expires_at: ?i64 = if (argv.len == 10) try std.fmt.parseInt(i64, argv[9], 10) else null;
    const now_ts = currentUnixSeconds(io);

    var db = try db_mod.Db.open(allocator, io, db_path);
    defer db.close();
    try db.initSchema();
    try db.writeMemory(.{
        .memory_key = memory_key,
        .mem_type = mem_type,
        .source = source,
        .content = content,
        .confidence = confidence,
        .salience = salience,
        .now_ts = now_ts,
        .expires_at = expires_at,
    });
    std.debug.print("memory upserted: {s}\n", .{memory_key});
}

fn runMemoryDelete(
    allocator: std.mem.Allocator,
    io: Io,
    db_path: []const u8,
    memory_key: []const u8,
    source: []const u8,
) !void {
    var db = try db_mod.Db.open(allocator, io, db_path);
    defer db.close();
    try db.initSchema();
    try db.deleteMemory(memory_key, source, currentUnixSeconds(io));
    std.debug.print("memory deleted: {s}\n", .{memory_key});
}

fn runMemoryTouch(
    allocator: std.mem.Allocator,
    io: Io,
    db_path: []const u8,
    memory_key: []const u8,
    source: []const u8,
) !void {
    var db = try db_mod.Db.open(allocator, io, db_path);
    defer db.close();
    try db.initSchema();
    try db.touchMemory(memory_key, source, currentUnixSeconds(io));
    std.debug.print("memory touched: {s}\n", .{memory_key});
}

fn runMemoryList(allocator: std.mem.Allocator, io: Io, db_path: []const u8, limit: usize) !void {
    var db = try db_mod.Db.open(allocator, io, db_path);
    defer db.close();
    try db.initSchema();

    const rows = try db.listMemoriesRanked(allocator, currentUnixSeconds(io), limit);
    defer db_mod.Db.freeMemoryRows(allocator, rows);

    for (rows) |row| {
        std.debug.print(
            "{s}\ttype={s}\tscore={d:.3}\tconfidence={d:.2}\tsalience={d:.2}\tcontent={s}\n",
            .{ row.memory_key, row.mem_type, row.rank_score, row.confidence, row.salience, row.content },
        );
    }
}

fn runMcpTools() !void {
    for (mcp_tools.default_tools) |tool| {
        std.debug.print(
            "{s}\tread_only={s}\t{s}\n",
            .{ tool.name, if (tool.read_only) "true" else "false", tool.description },
        );
    }
}

fn runDocPut(allocator: std.mem.Allocator, io: Io, argv: []const []const u8) !void {
    const db_path = argv[2];
    const collection = argv[3];
    const path = argv[4];
    const hash = argv[5];
    const content = argv[6];

    const embedding = if (argv.len == 8) try parseEmbeddingCsv(allocator, argv[7]) else null;
    defer if (embedding) |vec| allocator.free(vec);

    var engine = try api_mod.Engine.open(allocator, io, db_path);
    defer engine.close();

    const chunks = [_]api_mod.ChunkInput{.{
        .content = content,
        .embedding = embedding,
    }};
    try engine.upsertDocument(.{
        .collection = collection,
        .path = path,
        .hash = hash,
        .modified_at = currentUnixSeconds(io),
        .chunks = &chunks,
    });

    std.debug.print("document upserted: {s}/{s}\n", .{ collection, path });
}

fn runQuery(allocator: std.mem.Allocator, io: Io, argv: []const []const u8) !void {
    const db_path = argv[2];
    const query_text = argv[3];
    const limit = try std.fmt.parseUnsigned(usize, argv[4], 10);
    const collection: ?[]const u8 = if (argv.len >= 6 and !std.mem.eql(u8, argv[5], "-")) argv[5] else null;
    const embedding = if (argv.len == 7) try parseEmbeddingCsv(allocator, argv[6]) else null;
    defer if (embedding) |vec| allocator.free(vec);

    var engine = try api_mod.Engine.open(allocator, io, db_path);
    defer engine.close();

    const hits = try engine.hybridQuery(.{
        .query_text = query_text,
        .query_embedding = embedding,
        .collection = collection,
        .limit = limit,
    });
    defer api_mod.freeSearchHits(allocator, hits);

    for (hits) |hit| {
        std.debug.print(
            "[{s}] {s}\tfused={d:.3}\tlex={d:.3}\tvec={d:.3}\t{s}\n",
            .{ hit.collection, hit.path, hit.fused_score, hit.lexical_score, hit.vector_score, hit.content },
        );
    }
}

fn parseEmbeddingCsv(allocator: std.mem.Allocator, csv: []const u8) ![]f32 {
    var values = std.array_list.Managed(f32).init(allocator);
    errdefer values.deinit();

    var it = std.mem.tokenizeAny(u8, csv, ", ");
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, "\t\r\n");
        if (trimmed.len == 0) continue;
        const value = try std.fmt.parseFloat(f32, trimmed);
        try values.append(value);
    }

    return values.toOwnedSlice();
}

fn usage() void {
    std.debug.print(
        \\neon - Long-term AI assistant memory system
        \\
        \\Usage:
        \\  neon init <db-path>
        \\  neon memory-put <db-path> <memory-key> <type> <source> <confidence> <salience> <content> [expires_at_unix]
        \\  neon memory-delete <db-path> <memory-key> <source>
        \\  neon memory-touch <db-path> <memory-key> <source>
        \\  neon memory-list <db-path> [limit]
        \\  neon doc-put <db-path> <collection> <path> <hash> <chunk-content> [embedding_csv]
        \\  neon query <db-path> <query-text> <limit> [collection|-] [embedding_csv]
        \\  neon mcp-tools
        \\
    ,
        .{},
    );
}
