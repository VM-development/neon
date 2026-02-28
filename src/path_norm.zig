const std = @import("std");

pub const PathIdentity = struct {
    path_key: []u8,
    search_key: []u8,

    pub fn deinit(self: PathIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.path_key);
        allocator.free(self.search_key);
    }
};

pub const NormalizeError = std.mem.Allocator.Error || error{ EmptyPath, InvalidPath };

pub fn normalizePathIdentity(allocator: std.mem.Allocator, input: []const u8) NormalizeError!PathIdentity {
    if (input.len == 0) return error.EmptyPath;

    var segments = std.array_list.Managed([]const u8).init(allocator);
    defer segments.deinit();

    var replaced = std.array_list.Managed(u8).init(allocator);
    defer replaced.deinit();

    try replaced.ensureTotalCapacity(input.len);
    for (input) |ch| {
        try replaced.append(if (ch == '\\') '/' else ch);
    }

    var it = std.mem.splitScalar(u8, replaced.items, '/');
    while (it.next()) |raw_segment| {
        if (raw_segment.len == 0) continue;
        if (std.mem.eql(u8, raw_segment, ".")) continue;

        if (std.mem.eql(u8, raw_segment, "..")) {
            if (segments.items.len == 0) return error.InvalidPath;
            _ = segments.pop();
            continue;
        }
        try segments.append(raw_segment);
    }

    if (segments.items.len == 0) return error.EmptyPath;

    const path_key = try std.mem.join(allocator, "/", segments.items);
    errdefer allocator.free(path_key);

    var search = std.array_list.Managed(u8).init(allocator);
    defer search.deinit();
    for (path_key) |ch| {
        const lower = std.ascii.toLower(ch);
        if (std.ascii.isAlphanumeric(lower) or lower == '/' or lower == '.') {
            try search.append(lower);
        } else {
            // Keep lossy token-friendly path for retrieval, but never as unique key.
            if (search.items.len == 0 or search.items[search.items.len - 1] != '-') {
                try search.append('-');
            }
        }
    }

    return .{
        .path_key = path_key,
        .search_key = try search.toOwnedSlice(),
    };
}

test "path identity keeps case and punctuation distinct" {
    const alloc = std.testing.allocator;
    const a = try normalizePathIdentity(alloc, "Docs/Foo+Bar.md");
    defer a.deinit(alloc);
    const b = try normalizePathIdentity(alloc, "docs/foo bar.md");
    defer b.deinit(alloc);

    try std.testing.expect(!std.mem.eql(u8, a.path_key, b.path_key));
}

test "path identity normalizes separators without lowercasing uniqueness key" {
    const alloc = std.testing.allocator;
    const id = try normalizePathIdentity(alloc, ".\\Projects//Alpha/./Readme.MD");
    defer id.deinit(alloc);

    try std.testing.expectEqualStrings("Projects/Alpha/Readme.MD", id.path_key);
    try std.testing.expectEqualStrings("projects/alpha/readme.md", id.search_key);
}

test "path identity rejects empty and parent-only escapes" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.EmptyPath, normalizePathIdentity(alloc, ""));
    try std.testing.expectError(error.InvalidPath, normalizePathIdentity(alloc, "../outside.md"));
}
