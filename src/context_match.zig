const std = @import("std");

pub fn pathPrefixMatches(path: []const u8, prefix: []const u8) bool {
    const np = trimLeadingSlash(path);
    const npre = trimLeadingSlash(prefix);

    if (npre.len == 0) return true;
    if (!std.mem.startsWith(u8, np, npre)) return false;
    if (np.len == npre.len) return true;

    // Enforce segment boundary: "/work" matches "/work/a.md", not "/workshop/a.md".
    return np[npre.len] == '/';
}

fn trimLeadingSlash(input: []const u8) []const u8 {
    if (input.len > 0 and input[0] == '/') return input[1..];
    return input;
}

test "context prefix requires segment boundary" {
    try std.testing.expect(pathPrefixMatches("/work/doc.md", "/work"));
    try std.testing.expect(!pathPrefixMatches("/workshop/doc.md", "/work"));
}

test "context prefix handles exact path and root" {
    try std.testing.expect(pathPrefixMatches("/work", "/work"));
    try std.testing.expect(pathPrefixMatches("/anything/here", "/"));
}
