//! Graph collections (roadmap Phase 2).
//!
//! A graph collection stores labeled directed edges between nodes. A node is a
//! document-like object (id + named fields), so the document collection owns
//! node storage and its path semantics; this module adds the edge set and the
//! `navigate` traversal binding.
//!
//! This is the read-only graph slice: it defines node identity, labeled edges,
//! and one-hop traversal through `navigate`, and it does not imply multi-hop
//! path queries, shortest paths, transitive closures, or graph mutation beyond
//! adding nodes and edges.

const std = @import("std");
const Allocator = std.mem.Allocator;
const document_mod = @import("document.zig");
const value = @import("value.zig");

pub const Error = error{
    GraphExists,
    UnknownNode,
    DuplicateEdge,
} || Allocator.Error;

/// A directed, labeled edge `from --label--> to`.
pub const Edge = struct {
    from: []u8,
    label: []u8,
    to: []u8,

    pub fn deinit(self: *Edge, gpa: Allocator) void {
        gpa.free(self.from);
        gpa.free(self.label);
        gpa.free(self.to);
        self.* = undefined;
    }
};

/// A named graph. `nodes` reuses the document collection for node identity and
/// field storage; `edges` preserves insertion order for deterministic reads.
pub const Graph = struct {
    gpa: Allocator,
    name: []u8,
    nodes: document_mod.Collection,
    edges: std.ArrayList(Edge) = .empty,

    pub fn create(gpa: Allocator, name: []const u8) Allocator.Error!Graph {
        return .{
            .gpa = gpa,
            .name = try gpa.dupe(u8, name),
            .nodes = try document_mod.Collection.create(gpa, name),
        };
    }

    pub fn deinit(self: *Graph) void {
        self.nodes.deinit();
        for (self.edges.items) |*edge| edge.deinit(self.gpa);
        self.edges.deinit(self.gpa);
        self.gpa.free(self.name);
        self.* = undefined;
    }

    /// Add a node, rejecting a duplicate id. `fields` are cloned. Node
    /// validation is the document collection's, so the document error set is
    /// the node error set.
    pub fn addNode(self: *Graph, id: []const u8, fields: []const document_mod.Field) document_mod.Error!void {
        try self.nodes.insert(id, fields);
    }

    pub fn containsNode(self: *const Graph, id: []const u8) bool {
        return self.nodes.contains(id);
    }

    /// Add a directed labeled edge between two existing nodes. Duplicate
    /// `(from, label, to)` triples are rejected so the edge set stays unique.
    pub fn addEdge(self: *Graph, from: []const u8, label: []const u8, to: []const u8) Error!void {
        if (!self.nodes.contains(from) or !self.nodes.contains(to)) return error.UnknownNode;
        for (self.edges.items) |edge| {
            if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.label, label) and std.mem.eql(u8, edge.to, to)) {
                return error.DuplicateEdge;
            }
        }
        var edge: Edge = .{
            .from = try self.gpa.dupe(u8, from),
            .label = try self.gpa.dupe(u8, label),
            .to = try self.gpa.dupe(u8, to),
        };
        errdefer edge.deinit(self.gpa);
        try self.edges.append(self.gpa, edge);
    }
};

test "graph stores nodes and labeled edges and rejects duplicates" {
    const gpa = std.testing.allocator;
    var graph = try Graph.create(gpa, "social");
    defer graph.deinit();

    var name: value.Value = .{ .text = try gpa.dupe(u8, "Ada") };
    defer name.deinit(gpa);
    const fields = [_]document_mod.Field{
        .{ .path = @constCast("name"), .item = name },
    };
    try graph.addNode("1", &fields);
    try graph.addNode("2", &fields);
    try std.testing.expectError(error.DuplicateDocumentId, graph.addNode("1", &fields));
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.order.items.len);

    try graph.addEdge("1", "knows", "2");
    try std.testing.expectError(error.DuplicateEdge, graph.addEdge("1", "knows", "2"));
    try std.testing.expectError(error.UnknownNode, graph.addEdge("1", "knows", "99"));
    try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);
}
