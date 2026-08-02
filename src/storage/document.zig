//! Document collections (roadmap Phase 2).
//!
//! A document collection stores variable-shape objects keyed by a text id.
//! Each document holds an ordered set of named fields whose values are scalar
//! values. Fields are addressed by dotted path (for example `author.name`); a
//! path absent from a particular document reads as null. Collections are
//! populated through the engine API and the `document_insert` Runa Query IR
//! operation and read through Runa Flow.
//!
//! This is the read-only document slice: it defines document identity,
//! field-path projection, and predicate filtering, and it does not imply
//! World Continuum State Field or Representation Chart support, arrays,
//! schema evolution, or document mutation beyond insertion.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");

pub const Error = error{
    DocumentExists,
    DocumentNotFound,
    DuplicateDocumentId,
    MissingDocumentId,
    EmptyFieldPath,
} || Allocator.Error;

/// One named field of a document. `path` is a dotted path (for example
/// `author.name`); `item` is the scalar value. Both are owned.
pub const Field = struct {
    path: []u8,
    item: value.Value,

    pub fn deinit(self: *Field, gpa: Allocator) void {
        gpa.free(self.path);
        self.item.deinit(gpa);
        self.* = undefined;
    }
};

/// An immutable document: a text id plus an ordered field set.
pub const Document = struct {
    id: []u8,
    fields: std.ArrayList(Field) = .empty,

    pub fn deinit(self: *Document, gpa: Allocator) void {
        gpa.free(self.id);
        for (self.fields.items) |*field| field.deinit(gpa);
        self.fields.deinit(gpa);
        self.* = undefined;
    }

    /// Value for an exact dotted path, or null when the document lacks the
    /// field. A document never owns a null field entry; absence is the null.
    pub fn pathValue(self: *const Document, path: []const u8) ?value.Value {
        for (self.fields.items) |field| {
            if (std.mem.eql(u8, field.path, path)) return field.item;
        }
        return null;
    }
};

/// A named collection of documents. `order` preserves insertion order so reads
/// are deterministic (the same guarantee the relation slice gives for rows);
/// `by_id` provides identity lookup and duplicate rejection.
pub const Collection = struct {
    gpa: Allocator,
    name: []u8,
    by_id: std.StringHashMap(*Document) = undefined,
    order: std.ArrayList(*Document) = .empty,

    pub fn create(gpa: Allocator, name: []const u8) Allocator.Error!Collection {
        return .{
            .gpa = gpa,
            .name = try gpa.dupe(u8, name),
            .by_id = std.StringHashMap(*Document).init(gpa),
        };
    }

    pub fn deinit(self: *Collection) void {
        var it = self.by_id.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.gpa);
            self.gpa.destroy(entry.value_ptr.*);
        }
        self.by_id.deinit();
        self.order.deinit(self.gpa);
        self.gpa.free(self.name);
        self.* = undefined;
    }

    /// Insert a document, cloning `fields` and rejecting a duplicate id.
    /// The document is appended to read order only after the id is published,
    /// so a failed insert leaves both maps unchanged.
    pub fn insert(self: *Collection, id: []const u8, fields: []const Field) Error!void {
        if (id.len == 0) return error.MissingDocumentId;
        if (self.by_id.contains(id)) return error.DuplicateDocumentId;

        const owned = try self.gpa.create(Document);
        owned.* = .{ .id = try self.gpa.dupe(u8, id) };
        errdefer {
            owned.deinit(self.gpa);
            self.gpa.destroy(owned);
        }
        try owned.fields.ensureTotalCapacity(self.gpa, fields.len);
        for (fields) |*field| {
            if (field.path.len == 0) return error.EmptyFieldPath;
            const path = try self.gpa.dupe(u8, field.path);
            var item: value.Value = .null;
            item = field.item.clone(self.gpa) catch |err| {
                gpa: {
                    self.gpa.free(path);
                    break :gpa;
                }
                return err;
            };
            owned.fields.appendAssumeCapacity(.{ .path = path, .item = item });
        }
        try self.by_id.put(owned.id, owned);
        try self.order.append(self.gpa, owned);
    }

    pub fn contains(self: *const Collection, id: []const u8) bool {
        return self.by_id.contains(id);
    }
};

/// Build a collection from a reconstruction record: collection name, then a
/// stream of (id, fields) documents in WAL order. Used by recovery and by the
/// checkpoint rewrite, which share one deterministic field order.
pub fn reconstructCollection(
    gpa: Allocator,
    name: []const u8,
    docs: []const ReconstructDocument,
) Allocator.Error!Collection {
    var collection = try Collection.create(gpa, name);
    errdefer collection.deinit();
    for (docs) |doc| {
        try collection.insert(doc.id, doc.fields);
    }
    return collection;
}

/// A borrowed document for reconstruction: the id and fields are owned by the
/// caller and live only for the duration of the call.
pub const ReconstructDocument = struct {
    id: []const u8,
    fields: []const Field,
};

test "collection inserts documents in order and resolves paths" {
    const gpa = std.testing.allocator;
    var collection = try Collection.create(gpa, "books");
    defer collection.deinit();

    var title: value.Value = .{ .text = try gpa.dupe(u8, "Dune") };
    defer title.deinit(gpa);
    var author: value.Value = .{ .text = try gpa.dupe(u8, "Herbert") };
    defer author.deinit(gpa);
    const fields = [_]Field{
        .{ .path = @constCast("title"), .item = title },
        .{ .path = @constCast("author.name"), .item = author },
    };
    try collection.insert("1", &fields);

    try std.testing.expectEqual(@as(usize, 1), collection.order.items.len);
    const doc = collection.order.items[0];
    try std.testing.expectEqualStrings("1", doc.id);
    try std.testing.expectEqualStrings("Dune", doc.pathValue("title").?.text);
    try std.testing.expectEqualStrings("Herbert", doc.pathValue("author.name").?.text);
    try std.testing.expect(doc.pathValue("missing") == null);
    // A nested path absent at the exact dotted name reads as null.
    try std.testing.expect(doc.pathValue("author") == null);
}

test "collection rejects a duplicate document id" {
    const gpa = std.testing.allocator;
    var collection = try Collection.create(gpa, "books");
    defer collection.deinit();
    try collection.insert("1", &.{});
    try std.testing.expectError(error.DuplicateDocumentId, collection.insert("1", &.{}));
    try std.testing.expectError(error.MissingDocumentId, collection.insert("", &.{}));
    // Read order never gains a failed insert.
    try std.testing.expectEqual(@as(usize, 1), collection.order.items.len);
}
