const std = @import("std");

pub const VectorHit = struct {
    id: []const u8,
    collection: []const u8,
    distance: f64,
};

pub fn cosineDistanceToUnitScore(distance: f64) f64 {
    const clamped = std.math.clamp(distance, 0.0, 2.0);
    return 1.0 - (clamped / 2.0);
}

pub fn recommendedGlobalK(limit: usize, attempt: usize) usize {
    if (limit == 0) return 0;
    const base = limit * 4;
    const shift: u6 = @intCast(@min(attempt, 8));
    const scaled = base * (@as(usize, 1) << shift);
    return @min(scaled, 4096);
}

pub fn adaptiveCollectionFilter(
    allocator: std.mem.Allocator,
    sorted_hits: []const VectorHit,
    limit: usize,
    collection: ?[]const u8,
) ![]VectorHit {
    if (limit == 0) return allocator.alloc(VectorHit, 0);
    if (collection == null) {
        const take = @min(limit, sorted_hits.len);
        return allocator.dupe(VectorHit, sorted_hits[0..take]);
    }

    const wanted = collection.?;
    var attempt: usize = 0;
    var best = std.array_list.Managed(VectorHit).init(allocator);
    errdefer best.deinit();

    while (attempt < 10) : (attempt += 1) {
        const k = recommendedGlobalK(limit, attempt);
        const upto = @min(k, sorted_hits.len);

        best.clearRetainingCapacity();
        for (sorted_hits[0..upto]) |hit| {
            if (std.mem.eql(u8, hit.collection, wanted)) {
                try best.append(hit);
                if (best.items.len >= limit) break;
            }
        }

        if (best.items.len >= limit or upto == sorted_hits.len) break;
    }

    return best.toOwnedSlice();
}

test "vector score is always in documented 0..1 range" {
    try std.testing.expect(cosineDistanceToUnitScore(-1.2) <= 1.0);
    try std.testing.expect(cosineDistanceToUnitScore(-1.2) >= 0.0);
    try std.testing.expect(cosineDistanceToUnitScore(3.0) <= 1.0);
    try std.testing.expect(cosineDistanceToUnitScore(3.0) >= 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosineDistanceToUnitScore(0.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), cosineDistanceToUnitScore(1.0), 1e-9);
}

test "adaptive filter recovers recall when globally top-k misses collection" {
    const alloc = std.testing.allocator;
    const hits = [_]VectorHit{
        .{ .id = "a", .collection = "other", .distance = 0.01 },
        .{ .id = "b", .collection = "other", .distance = 0.02 },
        .{ .id = "c", .collection = "other", .distance = 0.03 },
        .{ .id = "d", .collection = "notes", .distance = 0.04 },
        .{ .id = "e", .collection = "notes", .distance = 0.05 },
        .{ .id = "f", .collection = "notes", .distance = 0.06 },
    };
    const filtered = try adaptiveCollectionFilter(alloc, &hits, 2, "notes");
    defer alloc.free(filtered);

    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqualStrings("d", filtered[0].id);
    try std.testing.expectEqualStrings("e", filtered[1].id);
}
