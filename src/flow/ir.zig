//! Canonical Runa Query IR for the initial read-only relation slice.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const value_mod = @import("../storage/value.zig");

pub const FORMAT_VERSION: u16 = 6;
pub const DEVELOPMENT_MODEL_REVISION: u64 = 0;

pub const IrError = error{
    InvalidFormat,
    UnsupportedVersion,
    StringTooLarge,
    ExpectedField,
    ExpectedLiteral,
    InvalidLiteral,
    InvalidIdentifier,
    InvalidOperation,
    InvalidModality,
    UnsupportedValue,
} || Allocator.Error;

pub const Operation = enum(u8) {
    emit = 1,
    observe = 2,
    read_evidence_payload = 3,
    /// Ingest one document into a named document collection (roadmap Phase 2).
    document_insert = 4,
    /// Add one node to a named graph (roadmap Phase 2).
    graph_add_node = 5,
    /// Add one directed labeled edge to a named graph (roadmap Phase 2).
    graph_add_edge = 6,
    /// Upsert one key/value pair into a named KV collection (roadmap Phase 2).
    kv_put = 7,
};

pub const Observe = struct {
    upload_id: u64,
    object_id: []u8,
    modality: u8,
    media_type: []u8,
    observed_at: []u8,
    origin: []u8,

    fn deinit(self: *Observe, gpa: Allocator) void {
        gpa.free(self.object_id);
        gpa.free(self.media_type);
        gpa.free(self.observed_at);
        gpa.free(self.origin);
    }
};

/// One typed field of a document insert. `item` is a scalar value owned by the
/// request; the engine clones it into the collection.
pub const DocumentField = struct {
    path: []u8,
    item: value_mod.Value,

    fn deinit(self: *DocumentField, gpa: Allocator) void {
        gpa.free(self.path);
        self.item.deinit(gpa);
        self.* = undefined;
    }
};

pub const DocumentInsert = struct {
    collection: []u8,
    id: []u8,
    fields: []DocumentField,

    fn deinit(self: *DocumentInsert, gpa: Allocator) void {
        gpa.free(self.collection);
        gpa.free(self.id);
        for (self.fields) |*field| field.deinit(gpa);
        gpa.free(self.fields);
        self.* = undefined;
    }
};

/// A `navigate` stage on a graph: follow outgoing edges labeled `edge`; the
/// destination node is addressable through `alias.<path>` in the emit.
pub const Navigate = struct {
    edge: []u8,
    alias: []u8,

    fn deinit(self: *Navigate, gpa: Allocator) void {
        gpa.free(self.edge);
        gpa.free(self.alias);
        self.* = undefined;
    }
};

pub const GraphAddNode = struct {
    graph: []u8,
    id: []u8,
    fields: []DocumentField,

    fn deinit(self: *GraphAddNode, gpa: Allocator) void {
        gpa.free(self.graph);
        gpa.free(self.id);
        for (self.fields) |*field| field.deinit(gpa);
        gpa.free(self.fields);
        self.* = undefined;
    }
};

pub const GraphAddEdge = struct {
    graph: []u8,
    from: []u8,
    label: []u8,
    to: []u8,

    fn deinit(self: *GraphAddEdge, gpa: Allocator) void {
        gpa.free(self.graph);
        gpa.free(self.from);
        gpa.free(self.label);
        gpa.free(self.to);
        self.* = undefined;
    }
};

/// One KV upsert: store `item` under text `key` in a named KV collection
/// (roadmap Phase 2). `item` is a scalar value owned by the request; the
/// engine clones it into the collection. Putting into a nonexistent collection
/// creates it on its first put.
pub const KvPut = struct {
    collection: []u8,
    key: []u8,
    item: value_mod.Value,

    fn deinit(self: *KvPut, gpa: Allocator) void {
        gpa.free(self.collection);
        gpa.free(self.key);
        self.item.deinit(gpa);
        self.* = undefined;
    }
};

pub const Request = struct {
    model_revision: u64,
    operation: Operation = .emit,
    relation: []u8,
    where: []ast.Predicate = &.{},
    fields: [][]u8,
    limit: ?u32 = null,
    observe: ?Observe = null,
    evidence_id: u64 = 0,
    document_insert: ?DocumentInsert = null,
    navigate: ?Navigate = null,
    graph_add_node: ?GraphAddNode = null,
    graph_add_edge: ?GraphAddEdge = null,
    kv_put: ?KvPut = null,

    pub fn deinit(self: *Request, gpa: Allocator) void {
        gpa.free(self.relation);
        for (self.where) |*predicate| predicate.deinit(gpa);
        gpa.free(self.where);
        if (self.navigate) |*navigate| navigate.deinit(gpa);
        for (self.fields) |field| gpa.free(field);
        gpa.free(self.fields);
        if (self.observe) |*request| request.deinit(gpa);
        if (self.document_insert) |*insert| insert.deinit(gpa);
        if (self.graph_add_node) |*insert| insert.deinit(gpa);
        if (self.graph_add_edge) |*edge| edge.deinit(gpa);
        if (self.kv_put) |*put| put.deinit(gpa);
    }
};

pub fn bind(gpa: Allocator, source: ast.Source) !Request {
    const relation = try gpa.dupe(u8, source.relation);
    errdefer gpa.free(relation);
    const predicates = try duplicatePredicates(gpa, source.where);
    errdefer {
        for (predicates) |*predicate| predicate.deinit(gpa);
        gpa.free(predicates);
    }
    var navigate = if (source.navigate) |*navigate_stage| blk: {
        var copied = try duplicateNavigate(gpa, navigate_stage);
        errdefer copied.deinit(gpa);
        break :blk copied;
    } else null;
    errdefer if (navigate) |*navigate_stage| navigate_stage.deinit(gpa);
    const fields = try duplicateFields(gpa, source.fields);
    const request = Request{ .model_revision = DEVELOPMENT_MODEL_REVISION, .relation = relation, .where = predicates, .navigate = navigate, .fields = fields, .limit = source.limit };
    try validate(&request);
    return request;
}

/// This encoding is canonical because all strings are bound identifiers and every
/// collection has a fixed order: version, model revision, operation, fields.
pub fn encode(gpa: Allocator, request: *const Request) ![]u8 {
    try validate(request);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try appendInt(&output, gpa, u16, FORMAT_VERSION);
    try appendInt(&output, gpa, u64, request.model_revision);
    try output.append(gpa, @intFromEnum(request.operation));
    switch (request.operation) {
        .emit => {
            try appendString(&output, gpa, request.relation);
            if (request.where.len > std.math.maxInt(u8)) return error.StringTooLarge;
            try output.append(gpa, @intCast(request.where.len));
            for (request.where) |*predicate| try appendPredicate(&output, gpa, predicate);
            if (request.fields.len > std.math.maxInt(u16)) return error.StringTooLarge;
            try appendInt(&output, gpa, u16, @intCast(request.fields.len));
            for (request.fields) |field| try appendString(&output, gpa, field);
            try output.append(gpa, if (request.limit != null) 1 else 0);
            if (request.limit) |limit| try appendInt(&output, gpa, u32, limit);
            try output.append(gpa, if (request.navigate != null) 1 else 0);
            if (request.navigate) |*navigate| {
                try appendString(&output, gpa, navigate.edge);
                try appendString(&output, gpa, navigate.alias);
            }
        },
        .observe => {
            const observation = request.observe.?;
            try appendInt(&output, gpa, u64, observation.upload_id);
            try appendString(&output, gpa, observation.object_id);
            try output.append(gpa, observation.modality);
            try appendString(&output, gpa, observation.media_type);
            try appendString(&output, gpa, observation.observed_at);
            try appendString(&output, gpa, observation.origin);
        },
        .read_evidence_payload => try appendInt(&output, gpa, u64, request.evidence_id),
        .document_insert => {
            const insert = request.document_insert.?;
            try appendString(&output, gpa, insert.collection);
            try appendString(&output, gpa, insert.id);
            if (insert.fields.len > std.math.maxInt(u16)) return error.StringTooLarge;
            try appendInt(&output, gpa, u16, @intCast(insert.fields.len));
            for (insert.fields) |*field| {
                try appendString(&output, gpa, field.path);
                try appendIrValue(&output, gpa, field.item);
            }
        },
        .graph_add_node => {
            const insert = request.graph_add_node.?;
            try appendString(&output, gpa, insert.graph);
            try appendString(&output, gpa, insert.id);
            if (insert.fields.len > std.math.maxInt(u16)) return error.StringTooLarge;
            try appendInt(&output, gpa, u16, @intCast(insert.fields.len));
            for (insert.fields) |*field| {
                try appendString(&output, gpa, field.path);
                try appendIrValue(&output, gpa, field.item);
            }
        },
        .graph_add_edge => {
            const edge = request.graph_add_edge.?;
            try appendString(&output, gpa, edge.graph);
            try appendString(&output, gpa, edge.from);
            try appendString(&output, gpa, edge.label);
            try appendString(&output, gpa, edge.to);
        },
        .kv_put => {
            const put = request.kv_put.?;
            try appendString(&output, gpa, put.collection);
            try appendString(&output, gpa, put.key);
            try appendIrValue(&output, gpa, put.item);
        },
    }
    return output.toOwnedSlice(gpa);
}

pub fn decode(gpa: Allocator, bytes: []const u8) IrError!Request {
    var pos: usize = 0;
    if (try readInt(u16, bytes, &pos) != FORMAT_VERSION) return error.UnsupportedVersion;
    const model_revision = try readInt(u64, bytes, &pos);
    if (pos >= bytes.len) return error.InvalidFormat;
    const operation = std.enums.fromInt(Operation, bytes[pos]) orelse return error.InvalidOperation;
    pos += 1;
    var relation: []u8 = try gpa.alloc(u8, 0);
    var predicates: []ast.Predicate = try gpa.alloc(ast.Predicate, 0);
    var fields: [][]u8 = try gpa.alloc([]u8, 0);
    var observation: ?Observe = null;
    var evidence_id: u64 = 0;
    var limit: ?u32 = null;
    var document_insert: ?DocumentInsert = null;
    var navigate_stage: ?Navigate = null;
    var graph_add_node: ?GraphAddNode = null;
    var graph_add_edge: ?GraphAddEdge = null;
    var kv_put: ?KvPut = null;
    var transferred = false;
    errdefer {
        if (!transferred) {
            gpa.free(relation);
            for (predicates) |*predicate| predicate.deinit(gpa);
            gpa.free(predicates);
            if (navigate_stage) |*navigate| navigate.deinit(gpa);
            for (fields) |field| gpa.free(field);
            gpa.free(fields);
            if (observation) |*item| item.deinit(gpa);
            if (document_insert) |*insert| insert.deinit(gpa);
            if (graph_add_node) |*insert| insert.deinit(gpa);
            if (graph_add_edge) |*edge| edge.deinit(gpa);
            if (kv_put) |*put| put.deinit(gpa);
        }
    }
    switch (operation) {
        .emit => {
            const parsed_relation = try readString(gpa, bytes, &pos);
            gpa.free(relation);
            relation = parsed_relation;
            if (pos >= bytes.len) return error.InvalidFormat;
            const predicate_count = bytes[pos];
            pos += 1;
            var predicate_list: std.ArrayList(ast.Predicate) = .empty;
            errdefer {
                for (predicate_list.items) |*predicate| predicate.deinit(gpa);
                predicate_list.deinit(gpa);
            }
            for (0..predicate_count) |_| try predicate_list.append(gpa, try decodePredicate(gpa, bytes, &pos));
            const parsed_predicates = try predicate_list.toOwnedSlice(gpa);
            gpa.free(predicates);
            predicates = parsed_predicates;
            const count = try readInt(u16, bytes, &pos);
            var list: std.ArrayList([]u8) = .empty;
            errdefer {
                for (list.items) |field| gpa.free(field);
                list.deinit(gpa);
            }
            for (0..count) |_| try list.append(gpa, try readString(gpa, bytes, &pos));
            const parsed_fields = try list.toOwnedSlice(gpa);
            gpa.free(fields);
            fields = parsed_fields;
            if (pos >= bytes.len) return error.InvalidFormat;
            const has_limit = bytes[pos];
            pos += 1;
            if (has_limit > 1) return error.InvalidFormat;
            if (has_limit == 1) limit = try readInt(u32, bytes, &pos);
            if (pos >= bytes.len) return error.InvalidFormat;
            const has_navigate = bytes[pos];
            pos += 1;
            if (has_navigate > 1) return error.InvalidFormat;
            if (has_navigate == 1) {
                const edge = try readString(gpa, bytes, &pos);
                errdefer gpa.free(edge);
                const alias = try readString(gpa, bytes, &pos);
                errdefer gpa.free(alias);
                navigate_stage = .{ .edge = edge, .alias = alias };
            }
        },
        .observe => observation = try decodeObserve(gpa, bytes, &pos),
        .read_evidence_payload => evidence_id = try readInt(u64, bytes, &pos),
        .document_insert => document_insert = try decodeDocumentInsert(gpa, bytes, &pos),
        .graph_add_node => graph_add_node = try decodeGraphAddNode(gpa, bytes, &pos),
        .graph_add_edge => graph_add_edge = try decodeGraphAddEdge(gpa, bytes, &pos),
        .kv_put => kv_put = try decodeKvPut(gpa, bytes, &pos),
    }
    if (pos != bytes.len) return error.InvalidFormat;
    var request = Request{
        .model_revision = model_revision,
        .operation = operation,
        .relation = relation,
        .where = predicates,
        .fields = fields,
        .limit = limit,
        .observe = observation,
        .evidence_id = evidence_id,
        .document_insert = document_insert,
        .navigate = navigate_stage,
        .graph_add_node = graph_add_node,
        .graph_add_edge = graph_add_edge,
        .kv_put = kv_put,
    };
    transferred = true;
    errdefer request.deinit(gpa);
    try validate(&request);
    return request;
}

fn decodeObserve(gpa: Allocator, bytes: []const u8, pos: *usize) IrError!Observe {
    const upload_id = try readInt(u64, bytes, pos);
    const object_id = try readString(gpa, bytes, pos);
    errdefer gpa.free(object_id);
    if (pos.* >= bytes.len) return error.InvalidFormat;
    const modality = bytes[pos.*];
    pos.* += 1;
    const media_type = try readString(gpa, bytes, pos);
    errdefer gpa.free(media_type);
    const observed_at = try readString(gpa, bytes, pos);
    errdefer gpa.free(observed_at);
    const origin = try readString(gpa, bytes, pos);
    return .{ .upload_id = upload_id, .object_id = object_id, .modality = modality, .media_type = media_type, .observed_at = observed_at, .origin = origin };
}

fn decodeDocumentInsert(gpa: Allocator, bytes: []const u8, pos: *usize) IrError!DocumentInsert {
    const collection = try readString(gpa, bytes, pos);
    errdefer gpa.free(collection);
    const id = try readString(gpa, bytes, pos);
    errdefer gpa.free(id);
    const count = try readInt(u16, bytes, pos);
    var fields: std.ArrayList(DocumentField) = .empty;
    errdefer {
        for (fields.items) |*field| field.deinit(gpa);
        fields.deinit(gpa);
    }
    try fields.ensureTotalCapacity(gpa, count);
    for (0..count) |_| {
        const path = try readString(gpa, bytes, pos);
        const item = try readIrValue(gpa, bytes, pos);
        fields.appendAssumeCapacity(.{ .path = path, .item = item });
    }
    return .{ .collection = collection, .id = id, .fields = try fields.toOwnedSlice(gpa) };
}

fn decodeGraphAddNode(gpa: Allocator, bytes: []const u8, pos: *usize) IrError!GraphAddNode {
    const graph = try readString(gpa, bytes, pos);
    errdefer gpa.free(graph);
    const id = try readString(gpa, bytes, pos);
    errdefer gpa.free(id);
    const count = try readInt(u16, bytes, pos);
    var fields: std.ArrayList(DocumentField) = .empty;
    errdefer {
        for (fields.items) |*field| field.deinit(gpa);
        fields.deinit(gpa);
    }
    try fields.ensureTotalCapacity(gpa, count);
    for (0..count) |_| {
        const path = try readString(gpa, bytes, pos);
        const item = try readIrValue(gpa, bytes, pos);
        fields.appendAssumeCapacity(.{ .path = path, .item = item });
    }
    return .{ .graph = graph, .id = id, .fields = try fields.toOwnedSlice(gpa) };
}

fn decodeGraphAddEdge(gpa: Allocator, bytes: []const u8, pos: *usize) IrError!GraphAddEdge {
    const graph = try readString(gpa, bytes, pos);
    errdefer gpa.free(graph);
    const from = try readString(gpa, bytes, pos);
    errdefer gpa.free(from);
    const label = try readString(gpa, bytes, pos);
    errdefer gpa.free(label);
    const to = try readString(gpa, bytes, pos);
    return .{ .graph = graph, .from = from, .label = label, .to = to };
}

fn decodeKvPut(gpa: Allocator, bytes: []const u8, pos: *usize) IrError!KvPut {
    const collection = try readString(gpa, bytes, pos);
    errdefer gpa.free(collection);
    const key = try readString(gpa, bytes, pos);
    errdefer gpa.free(key);
    const item = try readIrValue(gpa, bytes, pos);
    return .{ .collection = collection, .key = key, .item = item };
}

fn decodePredicate(gpa: Allocator, bytes: []const u8, pos: *usize) IrError!ast.Predicate {
    const column = try readString(gpa, bytes, pos);
    errdefer gpa.free(column);
    if (pos.* >= bytes.len) return error.InvalidFormat;
    const op = std.enums.fromInt(ast.Op, bytes[pos.*]) orelse return error.InvalidOperation;
    pos.* += 1;
    var scalar: ?ast.Literal = null;
    var list: std.ArrayList(ast.Literal) = .empty;
    errdefer {
        if (scalar) |*literal| literal.deinit(gpa);
        for (list.items) |*literal| literal.deinit(gpa);
        list.deinit(gpa);
    }
    switch (op) {
        .is_null, .not_null => {},
        .in, .not_in => {
            const literal_count = try readInt(u16, bytes, pos);
            if (literal_count == 0) return error.InvalidFormat;
            try list.ensureUnusedCapacity(gpa, literal_count);
            for (0..literal_count) |_| list.appendAssumeCapacity(try decodeLiteral(gpa, bytes, pos));
        },
        else => scalar = try decodeLiteral(gpa, bytes, pos),
    }
    return .{ .column = column, .op = op, .scalar = scalar, .list = list };
}

fn decodeLiteral(gpa: Allocator, bytes: []const u8, pos: *usize) IrError!ast.Literal {
    if (pos.* >= bytes.len) return error.InvalidFormat;
    const tag = bytes[pos.*];
    pos.* += 1;
    return switch (tag) {
        1 => .{ .int = try readInt(i64, bytes, pos) },
        2 => .{ .text = try readString(gpa, bytes, pos) },
        3 => blk: {
            if (pos.* >= bytes.len) return error.InvalidFormat;
            const boolean = bytes[pos.*];
            pos.* += 1;
            if (boolean > 1) return error.InvalidFormat;
            break :blk .{ .bool = boolean == 1 };
        },
        else => return error.InvalidFormat,
    };
}

/// Reject structures that cannot be produced by the Runa Flow source grammar.
/// This protects the canonical IR boundary when a client sends IR directly.
pub fn validate(request: *const Request) IrError!void {
    switch (request.operation) {
        .emit => {
            if (request.observe != null or request.evidence_id != 0 or request.document_insert != null or request.graph_add_node != null or request.graph_add_edge != null or request.kv_put != null) return error.InvalidOperation;
            if (!ast.isIdentifier(request.relation)) return error.InvalidIdentifier;
            for (request.where) |predicate| {
                // A relation column is a path of length one; a dotted path
                // addresses a nested document field. Binding resolves the path
                // against the named collection and rejects an unknown one.
                if (!ast.isPath(predicate.column)) return error.InvalidIdentifier;
                switch (predicate.op) {
                    .is_null, .not_null => {
                        if (predicate.scalar != null or predicate.list.items.len != 0) return error.InvalidOperation;
                    },
                    .like, .not_like => {
                        if (predicate.list.items.len != 0) return error.InvalidOperation;
                        const literal = predicate.scalar orelse return error.ExpectedLiteral;
                        if (literal != .text) return error.InvalidLiteral;
                    },
                    .in, .not_in => {
                        if (predicate.scalar != null) return error.InvalidOperation;
                        if (predicate.list.items.len == 0) return error.ExpectedLiteral;
                        const first = &predicate.list.items[0];
                        for (predicate.list.items[1..]) |*literal| {
                            if (!sameLiteralTag(first, literal)) return error.InvalidLiteral;
                        }
                    },
                    else => {
                        if (predicate.scalar == null) return error.ExpectedLiteral;
                        if (predicate.list.items.len != 0) return error.InvalidOperation;
                    },
                }
            }
            if (request.fields.len == 0) return error.ExpectedField;
            for (request.fields) |field| if (!ast.isPath(field)) return error.InvalidIdentifier;
            if (request.navigate) |*navigate| {
                if (!ast.isIdentifier(navigate.edge) or !ast.isIdentifier(navigate.alias)) return error.InvalidIdentifier;
            }
        },
        .observe => {
            const observation = request.observe orelse return error.InvalidOperation;
            if (request.relation.len != 0 or request.where.len != 0 or request.fields.len != 0 or request.evidence_id != 0 or request.limit != null or request.document_insert != null or request.navigate != null or request.graph_add_node != null or request.graph_add_edge != null or request.kv_put != null) return error.InvalidOperation;
            if (observation.upload_id == 0 or observation.object_id.len == 0 or observation.media_type.len == 0 or observation.observed_at.len == 0 or observation.origin.len == 0) return error.ExpectedField;
            if (observation.modality < 1 or observation.modality > 6) return error.InvalidModality;
        },
        .read_evidence_payload => {
            if (request.relation.len != 0 or request.where.len != 0 or request.fields.len != 0 or request.observe != null or request.evidence_id == 0 or request.limit != null or request.document_insert != null or request.navigate != null or request.graph_add_node != null or request.graph_add_edge != null or request.kv_put != null) return error.InvalidOperation;
        },
        .document_insert => {
            const insert = request.document_insert orelse return error.InvalidOperation;
            if (request.relation.len != 0 or request.where.len != 0 or request.fields.len != 0 or request.observe != null or request.evidence_id != 0 or request.limit != null or request.navigate != null or request.graph_add_node != null or request.graph_add_edge != null or request.kv_put != null) return error.InvalidOperation;
            if (insert.collection.len == 0 or insert.id.len == 0) return error.ExpectedField;
            if (!ast.isIdentifier(insert.collection)) return error.InvalidIdentifier;
            for (insert.fields) |*field| {
                if (!ast.isPath(field.path)) return error.InvalidIdentifier;
                if (field.item == .vector) return error.UnsupportedValue;
            }
        },
        .graph_add_node => {
            const insert = request.graph_add_node orelse return error.InvalidOperation;
            if (request.relation.len != 0 or request.where.len != 0 or request.fields.len != 0 or request.observe != null or request.evidence_id != 0 or request.limit != null or request.document_insert != null or request.navigate != null or request.graph_add_edge != null or request.kv_put != null) return error.InvalidOperation;
            if (insert.graph.len == 0 or insert.id.len == 0) return error.ExpectedField;
            if (!ast.isIdentifier(insert.graph)) return error.InvalidIdentifier;
            for (insert.fields) |*field| {
                if (!ast.isPath(field.path)) return error.InvalidIdentifier;
                if (field.item == .vector) return error.UnsupportedValue;
            }
        },
        .graph_add_edge => {
            const edge = request.graph_add_edge orelse return error.InvalidOperation;
            if (request.relation.len != 0 or request.where.len != 0 or request.fields.len != 0 or request.observe != null or request.evidence_id != 0 or request.limit != null or request.document_insert != null or request.navigate != null or request.graph_add_node != null or request.kv_put != null) return error.InvalidOperation;
            if (edge.graph.len == 0 or edge.from.len == 0 or edge.label.len == 0 or edge.to.len == 0) return error.ExpectedField;
            if (!ast.isIdentifier(edge.graph) or !ast.isIdentifier(edge.label)) return error.InvalidIdentifier;
        },
        .kv_put => {
            const put = request.kv_put orelse return error.InvalidOperation;
            if (request.relation.len != 0 or request.where.len != 0 or request.fields.len != 0 or request.observe != null or request.evidence_id != 0 or request.limit != null or request.document_insert != null or request.navigate != null or request.graph_add_node != null or request.graph_add_edge != null) return error.InvalidOperation;
            if (put.collection.len == 0 or put.key.len == 0) return error.ExpectedField;
            if (!ast.isIdentifier(put.collection)) return error.InvalidIdentifier;
            if (put.item == .vector) return error.UnsupportedValue;
        },
    }
}

fn sameLiteralTag(left: *const ast.Literal, right: *const ast.Literal) bool {
    return switch (left.*) {
        .int => right.* == .int,
        .text => right.* == .text,
        .bool => right.* == .bool,
    };
}

fn duplicatePredicates(gpa: Allocator, predicates: []const ast.Predicate) ![]ast.Predicate {
    const result = try gpa.alloc(ast.Predicate, predicates.len);
    errdefer gpa.free(result);
    var copied: usize = 0;
    errdefer for (result[0..copied]) |*predicate| predicate.deinit(gpa);
    for (predicates, 0..) |*predicate, index| {
        result[index] = try duplicatePredicate(gpa, predicate);
        copied += 1;
    }
    return result;
}

fn duplicatePredicate(gpa: Allocator, source: *const ast.Predicate) !ast.Predicate {
    const column = try gpa.dupe(u8, source.column);
    errdefer gpa.free(column);
    var scalar: ?ast.Literal = null;
    if (source.scalar) |*literal| scalar = try duplicateLiteral(gpa, literal);
    errdefer if (scalar) |*literal| literal.deinit(gpa);
    var list: std.ArrayList(ast.Literal) = .empty;
    errdefer {
        for (list.items) |*literal| literal.deinit(gpa);
        list.deinit(gpa);
    }
    try list.ensureUnusedCapacity(gpa, source.list.items.len);
    for (source.list.items) |*literal| list.appendAssumeCapacity(try duplicateLiteral(gpa, literal));
    return .{ .column = column, .op = source.op, .scalar = scalar, .list = list };
}

fn duplicateLiteral(gpa: Allocator, source: *const ast.Literal) !ast.Literal {
    return switch (source.*) {
        .int => |integer| .{ .int = integer },
        .bool => |boolean| .{ .bool = boolean },
        .text => |text| .{ .text = try gpa.dupe(u8, text) },
    };
}

fn duplicateNavigate(gpa: Allocator, source: *const ast.Navigate) !Navigate {
    return .{
        .edge = try gpa.dupe(u8, source.edge),
        .alias = try gpa.dupe(u8, source.alias),
    };
}

fn duplicateFields(gpa: Allocator, fields: []const []u8) ![][]u8 {
    const result = try gpa.alloc([]u8, fields.len);
    var copied: usize = 0;
    errdefer {
        for (result[0..copied]) |field| gpa.free(field);
        gpa.free(result);
    }
    for (fields, 0..) |field, index| {
        result[index] = try gpa.dupe(u8, field);
        copied += 1;
    }
    return result;
}

fn appendInt(output: *std.ArrayList(u8), gpa: Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .big);
    try output.appendSlice(gpa, &buffer);
}

fn appendString(output: *std.ArrayList(u8), gpa: Allocator, value: []const u8) !void {
    if (value.len > std.math.maxInt(u16)) return error.StringTooLarge;
    try appendInt(output, gpa, u16, @intCast(value.len));
    try output.appendSlice(gpa, value);
}

fn appendPredicate(output: *std.ArrayList(u8), gpa: Allocator, predicate: *const ast.Predicate) !void {
    try appendString(output, gpa, predicate.column);
    try output.append(gpa, @intFromEnum(predicate.op));
    switch (predicate.op) {
        .is_null, .not_null => {},
        .in, .not_in => {
            if (predicate.list.items.len > std.math.maxInt(u16)) return error.StringTooLarge;
            try appendInt(output, gpa, u16, @intCast(predicate.list.items.len));
            for (predicate.list.items) |*literal| try appendLiteral(output, gpa, literal);
        },
        else => try appendLiteral(output, gpa, &predicate.scalar.?),
    }
}

fn appendLiteral(output: *std.ArrayList(u8), gpa: Allocator, literal: *const ast.Literal) !void {
    switch (literal.*) {
        .int => |integer| {
            try output.append(gpa, 1);
            try appendInt(output, gpa, i64, integer);
        },
        .text => |text| {
            try output.append(gpa, 2);
            try appendString(output, gpa, text);
        },
        .bool => |boolean| {
            try output.append(gpa, 3);
            try output.append(gpa, if (boolean) 1 else 0);
        },
    }
}

/// Canonical scalar encoding for document values. Documents are scalar-only in
/// this slice, so a vector value is rejected rather than silently stored.
fn appendIrValue(output: *std.ArrayList(u8), gpa: Allocator, item: value_mod.Value) IrError!void {
    switch (item) {
        .null => try output.append(gpa, 0),
        .int => |integer| {
            try output.append(gpa, 1);
            try appendInt(output, gpa, i64, integer);
        },
        .text => |text| {
            try output.append(gpa, 2);
            try appendString(output, gpa, text);
        },
        .bool => |boolean| {
            try output.append(gpa, 3);
            try output.append(gpa, if (boolean) 1 else 0);
        },
        .vector => return error.UnsupportedValue,
    }
}

fn readIrValue(gpa: Allocator, bytes: []const u8, pos: *usize) IrError!value_mod.Value {
    if (pos.* >= bytes.len) return error.InvalidFormat;
    const tag = bytes[pos.*];
    pos.* += 1;
    return switch (tag) {
        0 => .null,
        1 => .{ .int = try readInt(i64, bytes, pos) },
        2 => .{ .text = try readString(gpa, bytes, pos) },
        3 => blk: {
            if (pos.* >= bytes.len) return error.InvalidFormat;
            const boolean = bytes[pos.*];
            pos.* += 1;
            if (boolean > 1) return error.InvalidFormat;
            break :blk .{ .bool = boolean == 1 };
        },
        else => return error.InvalidFormat,
    };
}

fn readInt(comptime T: type, bytes: []const u8, pos: *usize) IrError!T {
    if (bytes.len -| pos.* < @sizeOf(T)) return error.InvalidFormat;
    const value = std.mem.readInt(T, bytes[pos.*..][0..@sizeOf(T)], .big);
    pos.* += @sizeOf(T);
    return value;
}

fn readString(gpa: Allocator, bytes: []const u8, pos: *usize) IrError![]u8 {
    const length = try readInt(u16, bytes, pos);
    if (bytes.len -| pos.* < length) return error.InvalidFormat;
    const result = try gpa.dupe(u8, bytes[pos.* .. pos.* + length]);
    pos.* += length;
    return result;
}

test "IR encoding round trips exactly" {
    var source = try ast.parse(std.testing.allocator, "from customer\n| where id >= 5\n| where name like 'a%'\n| emit { id, name }\n| limit 12");
    defer source.deinit(std.testing.allocator);
    var request = try bind(std.testing.allocator, source);
    defer request.deinit(std.testing.allocator);
    const bytes = try encode(std.testing.allocator, &request);
    defer std.testing.allocator.free(bytes);
    var decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("customer", decoded.relation);
    try std.testing.expectEqual(@as(usize, 2), decoded.where.len);
    try std.testing.expectEqual(ast.Op.gte, decoded.where[0].op);
    try std.testing.expectEqual(@as(i64, 5), decoded.where[0].scalar.?.int);
    try std.testing.expectEqual(ast.Op.like, decoded.where[1].op);
    try std.testing.expectEqualStrings("a%", decoded.where[1].scalar.?.text);
    try std.testing.expectEqualStrings("name", decoded.fields[1]);
    try std.testing.expectEqual(@as(?u32, 12), decoded.limit);
}

test "IR decode rejects an empty projection" {
    const bytes = [_]u8{
        0, 6, // format version
        0, 0, 0, 0, 0, 0, 0, 0, // model revision
        1, // emit operation
        0, 8, 'c', 'u', 's', 't', 'o', 'm', 'e', 'r', // relation
        0, // where predicate count
        0, 0, // field count
        0, // no limit
        0, // no navigate
    };
    try std.testing.expectError(error.ExpectedField, decode(std.testing.allocator, &bytes));
}

test "IR encode rejects identifiers outside the source grammar" {
    var fields = [_][]u8{@constCast("name")};
    const request = Request{
        .model_revision = DEVELOPMENT_MODEL_REVISION,
        .relation = @constCast("customer-name"),
        .fields = fields[0..],
    };
    try std.testing.expectError(error.InvalidIdentifier, encode(std.testing.allocator, &request));
}

test "IR decode rejects an invalid limit presence flag" {
    const bytes = [_]u8{
        0, 6, // format version
        0, 0, 0, 0, 0, 0, 0, 0, // model revision
        1, // emit operation
        0, 8, 'c', 'u', 's', 't', 'o', 'm', 'e', 'r', // relation
        0, // where predicate count
        0,   1, // field count
        0,   2,
        'i', 'd',
        2, // invalid limit presence flag
    };
    try std.testing.expectError(error.InvalidFormat, decode(std.testing.allocator, &bytes));
}

test "IR decode rejects an invalid predicate op" {
    const bytes = [_]u8{
        0, 6, // format version
        0, 0, 0, 0, 0, 0, 0, 0, // model revision
        1, // emit operation
        0, 8, 'c', 'u', 's', 't', 'o', 'm', 'e', 'r', // relation
        1, // one where predicate
        0, 2, 'i', 'd', // column
        99, // invalid op
    };
    try std.testing.expectError(error.InvalidOperation, decode(std.testing.allocator, &bytes));
}

test "IR decode rejects an invalid in-list literal tag" {
    const bytes = [_]u8{
        0, 6, // format version
        0, 0, 0, 0, 0, 0, 0, 0, // model revision
        1, // emit operation
        0, 8, 'c', 'u', 's', 't', 'o', 'm', 'e', 'r', // relation
        1, // one where predicate
        0, 2, 'i', 'd', // column
        @intFromEnum(ast.Op.in), // op
        0, 1, // one literal
        9, // invalid literal tag
    };
    try std.testing.expectError(error.InvalidFormat, decode(std.testing.allocator, &bytes));
}

test "IR encode rejects a non-homogeneous in list" {
    const gpa = std.testing.allocator;
    var predicate: ast.Predicate = .{
        .column = try gpa.dupe(u8, "id"),
        .op = .in,
    };
    defer predicate.deinit(gpa);
    try predicate.list.append(gpa, .{ .int = 1 });
    try predicate.list.append(gpa, .{ .text = try gpa.dupe(u8, "x") });
    var predicates = [_]ast.Predicate{predicate};
    var fields = [_][]u8{@constCast("id")};
    const request = Request{
        .model_revision = DEVELOPMENT_MODEL_REVISION,
        .relation = @constCast("customer"),
        .where = predicates[0..],
        .fields = fields[0..],
    };
    try std.testing.expectError(error.InvalidLiteral, encode(std.testing.allocator, &request));
}

test "IR encode rejects a non-text like pattern" {
    const gpa = std.testing.allocator;
    var predicate: ast.Predicate = .{
        .column = try gpa.dupe(u8, "name"),
        .op = .like,
        .scalar = .{ .int = 5 },
    };
    defer predicate.deinit(gpa);
    var predicates = [_]ast.Predicate{predicate};
    var fields = [_][]u8{@constCast("id")};
    const request = Request{
        .model_revision = DEVELOPMENT_MODEL_REVISION,
        .relation = @constCast("customer"),
        .where = predicates[0..],
        .fields = fields[0..],
    };
    try std.testing.expectError(error.InvalidLiteral, encode(std.testing.allocator, &request));
}

test "IR encode rejects an is null predicate with a literal" {
    const gpa = std.testing.allocator;
    var predicate: ast.Predicate = .{
        .column = try gpa.dupe(u8, "region"),
        .op = .is_null,
        .scalar = .{ .int = 1 },
    };
    defer predicate.deinit(gpa);
    var predicates = [_]ast.Predicate{predicate};
    var fields = [_][]u8{@constCast("id")};
    const request = Request{
        .model_revision = DEVELOPMENT_MODEL_REVISION,
        .relation = @constCast("customer"),
        .where = predicates[0..],
        .fields = fields[0..],
    };
    try std.testing.expectError(error.InvalidOperation, encode(std.testing.allocator, &request));
}

test "IR decodes a canonical observe request" {
    const bytes = [_]u8{
        0, 6, // format version
        0, 0, 0, 0, 0, 0, 0, 0, // model revision
        2, // observe operation
        0, 0, 0,   0,   0,   0, 0, 7, // upload id
        0, 3, 'c', 'a', 'm',
        2, // image modality
        0,
        9,
        'i',
        'm',
        'a',
        'g',
        'e',
        '/',
        'p',
        'n',
        'g',
        0,
        1,
        't',
        0,
        1,
        'o',
    };
    var request = try decode(std.testing.allocator, &bytes);
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(Operation.observe, request.operation);
    try std.testing.expectEqual(@as(u64, 7), request.observe.?.upload_id);
    try std.testing.expectEqualStrings("image/png", request.observe.?.media_type);
}

test "document_insert IR round trips exactly" {
    const gpa = std.testing.allocator;
    const fields = try gpa.alloc(DocumentField, 3);
    fields[0] = .{ .path = try gpa.dupe(u8, "title"), .item = .{ .text = try gpa.dupe(u8, "Dune") } };
    fields[1] = .{ .path = try gpa.dupe(u8, "pages"), .item = .{ .int = 412 } };
    fields[2] = .{ .path = try gpa.dupe(u8, "featured"), .item = .{ .bool = true } };
    // The Request owns the collection, id, fields slice, and each field.
    var request = Request{
        .model_revision = DEVELOPMENT_MODEL_REVISION,
        .operation = .document_insert,
        .relation = @constCast(""),
        .fields = &.{},
        .document_insert = .{
            .collection = try gpa.dupe(u8, "books"),
            .id = try gpa.dupe(u8, "1"),
            .fields = fields,
        },
    };
    defer request.deinit(gpa);
    const bytes = try encode(gpa, &request);
    defer gpa.free(bytes);
    var decoded = try decode(gpa, bytes);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(Operation.document_insert, decoded.operation);
    try std.testing.expectEqualStrings("books", decoded.document_insert.?.collection);
    try std.testing.expectEqualStrings("1", decoded.document_insert.?.id);
    try std.testing.expectEqual(@as(usize, 3), decoded.document_insert.?.fields.len);
    try std.testing.expectEqualStrings("title", decoded.document_insert.?.fields[0].path);
    try std.testing.expectEqual(@as(i64, 412), decoded.document_insert.?.fields[1].item.int);
    try std.testing.expectEqual(true, decoded.document_insert.?.fields[2].item.bool);
}

test "kv_put IR round trips exactly" {
    const gpa = std.testing.allocator;
    var request = Request{
        .model_revision = DEVELOPMENT_MODEL_REVISION,
        .operation = .kv_put,
        .relation = @constCast(""),
        .fields = &.{},
        .kv_put = .{
            .collection = try gpa.dupe(u8, "cache"),
            .key = try gpa.dupe(u8, "region"),
            .item = .{ .text = try gpa.dupe(u8, "north") },
        },
    };
    defer request.deinit(gpa);
    const bytes = try encode(gpa, &request);
    defer gpa.free(bytes);
    var decoded = try decode(gpa, bytes);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(Operation.kv_put, decoded.operation);
    try std.testing.expectEqualStrings("cache", decoded.kv_put.?.collection);
    try std.testing.expectEqualStrings("region", decoded.kv_put.?.key);
    try std.testing.expectEqualStrings("north", decoded.kv_put.?.item.text);

    // Int and bool values round trip too.
    var int_request = Request{
        .model_revision = DEVELOPMENT_MODEL_REVISION,
        .operation = .kv_put,
        .relation = @constCast(""),
        .fields = &.{},
        .kv_put = .{
            .collection = try gpa.dupe(u8, "cache"),
            .key = try gpa.dupe(u8, "retries"),
            .item = .{ .int = 3 },
        },
    };
    defer int_request.deinit(gpa);
    const int_bytes = try encode(gpa, &int_request);
    defer gpa.free(int_bytes);
    var int_decoded = try decode(gpa, int_bytes);
    defer int_decoded.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 3), int_decoded.kv_put.?.item.int);
}

test "kv_put IR rejects a vector value and a non-identifier collection" {
    const gpa = std.testing.allocator;
    var vector_request = Request{
        .model_revision = DEVELOPMENT_MODEL_REVISION,
        .operation = .kv_put,
        .relation = @constCast(""),
        .fields = &.{},
        .kv_put = .{
            .collection = try gpa.dupe(u8, "cache"),
            .key = try gpa.dupe(u8, "k"),
            .item = .{ .vector = try gpa.dupe(f32, &.{ 1, 2 }) },
        },
    };
    defer vector_request.deinit(gpa);
    try std.testing.expectError(error.UnsupportedValue, encode(gpa, &vector_request));

    var name_request = Request{
        .model_revision = DEVELOPMENT_MODEL_REVISION,
        .operation = .kv_put,
        .relation = @constCast(""),
        .fields = &.{},
        .kv_put = .{
            .collection = try gpa.dupe(u8, "cache-name"),
            .key = try gpa.dupe(u8, "k"),
            .item = .{ .int = 1 },
        },
    };
    defer name_request.deinit(gpa);
    try std.testing.expectError(error.InvalidIdentifier, encode(gpa, &name_request));
}
