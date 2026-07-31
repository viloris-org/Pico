//! Bounded vector retrieval primitives.
//!
//! Embeddings are supplied by the caller. RunaDB does not run a model or infer
//! an embedding from Observation Evidence; this module only validates vectors
//! and ranks already-materialized representations.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    EmptyVector,
    DimensionMismatch,
    NonFiniteComponent,
    InvalidLimit,
};

pub const Metric = enum {
    cosine,
    euclidean_squared,
    dot_product,
};

/// An embedding supplied by an external model or application. The slice is
/// borrowed; callers retain ownership for the duration of a retrieval call.
pub const Embedding = []const f32;

pub const Entry = struct {
    row_index: usize,
    embedding: Embedding,
};

pub const Candidate = struct {
    row_index: usize,
    /// Higher scores rank first. Euclidean scores are negative squared distance.
    score: f32,
};

pub fn validate(vector: []const f32) Error!void {
    if (vector.len == 0) return error.EmptyVector;
    for (vector) |component| if (!std.math.isFinite(component)) return error.NonFiniteComponent;
}

pub fn score(metric: Metric, query: []const f32, candidate: []const f32) Error!f32 {
    try validate(query);
    try validate(candidate);
    if (query.len != candidate.len) return error.DimensionMismatch;

    var dot: f32 = 0;
    var query_norm: f32 = 0;
    var candidate_norm: f32 = 0;
    var squared: f32 = 0;
    for (query, candidate) |q, c| {
        dot += q * c;
        query_norm += q * q;
        candidate_norm += c * c;
        const delta = q - c;
        squared += delta * delta;
    }
    return switch (metric) {
        .dot_product => dot,
        .euclidean_squared => -squared,
        .cosine => if (query_norm == 0 or candidate_norm == 0) 0 else dot / (@sqrt(query_norm) * @sqrt(candidate_norm)),
    };
}

/// Return at most `limit` entries, ordered by descending score and then row
/// index. A zero limit is rejected so accidental unbounded scans are visible.
pub fn topK(gpa: Allocator, entries: []const Entry, query: []const f32, metric: Metric, limit: usize) (Error || Allocator.Error)![]Candidate {
    if (limit == 0) return error.InvalidLimit;
    try validate(query);
    var result: std.ArrayList(Candidate) = .empty;
    errdefer result.deinit(gpa);
    for (entries) |entry| {
        const candidate_score = try score(metric, query, entry.embedding);
        try result.append(gpa, .{ .row_index = entry.row_index, .score = candidate_score });
    }
    std.sort.heap(Candidate, result.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.score == b.score) return a.row_index < b.row_index;
            return a.score > b.score;
        }
    }.lessThan);
    if (result.items.len > limit) result.shrinkRetainingCapacity(limit);
    return result.toOwnedSlice(gpa);
}

test "scores vectors and keeps deterministic top k order" {
    const entries = [_]Entry{
        .{ .row_index = 2, .embedding = &[_]f32{ 0, 1 } },
        .{ .row_index = 1, .embedding = &[_]f32{ 1, 0 } },
        .{ .row_index = 3, .embedding = &[_]f32{ 0, 1 } },
    };
    const ranked = try topK(std.testing.allocator, &entries, &[_]f32{ 0, 1 }, .cosine, 2);
    defer std.testing.allocator.free(ranked);
    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    try std.testing.expectEqual(@as(usize, 2), ranked[0].row_index);
    try std.testing.expectEqual(@as(usize, 3), ranked[1].row_index);
}

test "rejects malformed vectors" {
    try std.testing.expectError(error.DimensionMismatch, score(.dot_product, &[_]f32{ 1 }, &[_]f32{ 1, 2 }));
    try std.testing.expectError(error.NonFiniteComponent, validate(&[_]f32{std.math.nan(f32)}));
    try std.testing.expectError(error.InvalidLimit, topK(std.testing.allocator, &.{}, &[_]f32{1}, .cosine, 0));
}
