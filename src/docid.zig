const std = @import("std");

pub const ResolveResult = union(enum) {
    found: []const u8,
    ambiguous,
    not_found,
};

pub const ResolveError = error{
    InvalidPrefix,
};

pub fn normalizeDocidPrefix(input: []const u8, out: *[128]u8) ResolveError![]const u8 {
    var trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPrefix;

    if ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
        (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))
    {
        if (trimmed.len < 3) return error.InvalidPrefix;
        trimmed = trimmed[1 .. trimmed.len - 1];
    }
    if (trimmed.len > 0 and trimmed[0] == '#') {
        trimmed = trimmed[1..];
    }

    if (trimmed.len < 8 or trimmed.len > out.len) return error.InvalidPrefix;
    if (!isHex(trimmed)) return error.InvalidPrefix;

    for (trimmed, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out[0..trimmed.len];
}

pub fn resolveDocidPrefix(prefix: []const u8, hashes: []const []const u8) ResolveResult {
    var hit: ?[]const u8 = null;
    for (hashes) |hash| {
        if (hash.len < prefix.len) continue;
        if (std.ascii.eqlIgnoreCase(hash[0..prefix.len], prefix)) {
            if (hit != null) return .ambiguous;
            hit = hash;
        }
    }
    if (hit) |value| return .{ .found = value };
    return .not_found;
}

fn isHex(value: []const u8) bool {
    for (value) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

test "docid normalization accepts lenient quoted hash syntax" {
    var buf: [128]u8 = undefined;
    const normalized = try normalizeDocidPrefix("\"#ABCD1234\"", &buf);
    try std.testing.expectEqualStrings("abcd1234", normalized);
}

test "docid resolution reports ambiguity instead of picking LIMIT 1" {
    const hashes = [_][]const u8{
        "abcd1234ffff",
        "abcd12345555",
        "deadbeef0000",
    };
    const result = resolveDocidPrefix("abcd1234", &hashes);
    try std.testing.expect(result == .ambiguous);
}

test "docid normalization rejects too-short values" {
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidPrefix, normalizeDocidPrefix("abc123", &buf));
}
