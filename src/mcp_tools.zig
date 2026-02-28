const std = @import("std");

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    read_only: bool,
};

pub const default_tools = [_]Tool{
    .{
        .name = "query",
        .description = "Hybrid lexical/vector/rerank query tool.",
        .read_only = true,
    },
    .{
        .name = "get",
        .description = "Read a document by path or id.",
        .read_only = true,
    },
    .{
        .name = "status",
        .description = "Show index and model status.",
        .read_only = true,
    },
    .{
        .name = "memory_put",
        .description = "Create or update a memory record (append event + refresh current view).",
        .read_only = false,
    },
    .{
        .name = "memory_delete",
        .description = "Tombstone a memory record (append delete event + remove current view).",
        .read_only = false,
    },
    .{
        .name = "memory_touch",
        .description = "Update access metadata to improve recency-aware ranking.",
        .read_only = false,
    },
};

pub fn findTool(name: []const u8) ?Tool {
    for (default_tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

test "tool registry includes write-capable memory operations" {
    const put = findTool("memory_put") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!put.read_only);

    const del = findTool("memory_delete") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!del.read_only);
}
