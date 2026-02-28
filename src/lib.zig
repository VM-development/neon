pub const db = @import("db.zig");
pub const path_norm = @import("path_norm.zig");
pub const docid = @import("docid.zig");
pub const context_match = @import("context_match.zig");
pub const vector = @import("vector.zig");
pub const rerank = @import("rerank.zig");
pub const mcp_tools = @import("mcp_tools.zig");
pub const api = @import("api.zig");

test {
    _ = db;
    _ = path_norm;
    _ = docid;
    _ = context_match;
    _ = vector;
    _ = rerank;
    _ = mcp_tools;
    _ = api;
}
