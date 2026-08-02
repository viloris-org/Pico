//! Bind and execute the initial read-only Runa Flow relation slice.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const engine_mod = @import("../storage/engine.zig");
const table_mod = @import("../storage/table.zig");
const document_mod = @import("../storage/document.zig");
const value = @import("../storage/value.zig");
const evidence = @import("../storage/evidence.zig");
const txn_mod = @import("../txn/transaction.zig");

pub const ExecError = ast.ParseError || ir.IrError || error{
    SemanticNameNotFound,
    FieldNotFound,
    TypeMismatch,
    NonComparableColumn,
    ModelRevisionMismatch,
    UnsupportedNavigate,
    Canceled,
} || Allocator.Error;

pub const Result = struct {
    columns: [][]const u8,
    cells: [][]?[]const u8,
    owned_text: std.ArrayList([]u8),
    gpa: Allocator,

    pub fn deinit(self: *Result) void {
        self.gpa.free(self.columns);
        for (self.cells) |row| self.gpa.free(row);
        self.gpa.free(self.cells);
        for (self.owned_text.items) |text| self.gpa.free(text);
        self.owned_text.deinit(self.gpa);
    }
};

/// Cooperative cancellation probe (roadmap Phase 6). The caller — a RunaDB
/// Connection — owns the state and the statement generation that a
/// `CANCEL_REQUEST` marks; the flow module only calls `check` between bounded
/// work units during scan execution and never stores the probe past the call.
/// A null probe disables cancellation, preserving the engine-level and MCP call
/// paths unchanged.
pub const CancelProbe = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque) error{Canceled}!void,
};

/// Per-execution options. The default options carry no cancellation probe.
pub const ExecOptions = struct {
    cancel: ?CancelProbe = null,
};

/// Report the owning Connection's cancellation mark between bounded work units.
/// A marked statement stops at the next row boundary with `error.Canceled`,
/// which the protocol layer maps to the delivered `CANCELED` outcome (`RF1006`).
fn checkCancel(opts: ExecOptions) ExecError!void {
    if (opts.cancel) |probe| try probe.check(probe.ctx);
}

/// Duplicate a column name into `owned` and return the owned slice. Result
/// column metadata is fully owned (Phase 6): a DDL that frees engine column
/// state cannot race a result still being sent, because no borrowed engine
/// memory escapes the statement-execution lock. Behavior is byte-identical to
/// borrowing the name.
fn ownColumn(gpa: Allocator, owned: *std.ArrayList([]u8), name: []const u8) ![]const u8 {
    const copy = try gpa.dupe(u8, name);
    errdefer gpa.free(copy);
    try owned.append(gpa, copy);
    return copy;
}

pub fn compile(gpa: Allocator, source: []const u8) !ir.Request {
    var parsed = try ast.parse(gpa, source);
    defer parsed.deinit(gpa);
    return ir.bind(gpa, parsed);
}

pub fn execute(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request) ExecError!Result {
    return executeOpts(gpa, eng, request, .{});
}

/// Execute a Request with optional cooperative cancellation: the scan loops
/// check `opts.cancel` between bounded work units, so a Connection's
/// `CANCEL_REQUEST` mark stops a long scan at the next row boundary. The plain
/// `execute` entry point passes the default options and never observes
/// cancellation.
pub fn executeOpts(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, opts: ExecOptions) ExecError!Result {
    if (request.model_revision != ir.DEVELOPMENT_MODEL_REVISION) return error.ModelRevisionMismatch;
    if (request.operation != .emit) return error.InvalidOperation;
    if (std.mem.eql(u8, request.relation, "observation_evidence")) return executeEvidence(gpa, eng, request, opts);
    // Revision 0 is an explicit development binding of relation, document, and
    // graph names to the existing catalog. It is read-only and is not persisted
    // as a model.
    if (eng.getDocumentCollection(request.relation)) |_| {
        if (request.navigate != null) return error.UnsupportedNavigate;
        return executeDocument(gpa, eng, request, opts);
    }
    if (eng.getGraph(request.relation) != null) return executeGraph(gpa, eng, request, opts);
    const table = eng.getTable(request.relation) orelse return error.SemanticNameNotFound;
    if (request.navigate != null) return error.UnsupportedNavigate;
    const projection = try bindProjection(gpa, table, request.fields);
    defer gpa.free(projection);

    var owned_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_text.items) |text| gpa.free(text);
        owned_text.deinit(gpa);
    }
    const columns = try gpa.alloc([]const u8, projection.len);
    errdefer gpa.free(columns);
    for (projection, 0..) |index, output_index| {
        columns[output_index] = try ownColumn(gpa, &owned_text, table.columns[index].name);
    }
    var cells: std.ArrayList([]?[]const u8) = .empty;
    errdefer {
        for (cells.items) |row| gpa.free(row);
        cells.deinit(gpa);
    }

    var bound = try bindTableWhere(gpa, table, request.where);
    defer bound.deinit();

    // Read Committed: the statement takes a fresh snapshot watermark at its
    // start and interprets only complete commits at or before it. The engine's
    // snapshot-aware scan registers the watermark for the read's duration and
    // returns only versions visible at it; the Flow slice keeps reading them
    // even as later commits land (reads do not wait for writes).
    const snapshot_seq = eng.publishedSeq();
    var visible = eng.selectAll(request.relation, snapshot_seq) catch |err| return switch (err) {
        error.TableNotFound => error.SemanticNameNotFound,
        error.SnapshotLimitExceeded => error.OutOfMemory,
        error.OutOfMemory => error.OutOfMemory,
    };
    defer visible.deinit();

    const max_rows: usize = if (request.limit) |limit| @intCast(limit) else std.math.maxInt(usize);
    var emitted: usize = 0;
    for (visible.rows) |row| {
        if (emitted >= max_rows) break;
        try checkCancel(opts);
        if (!table_mod.valuesMatch(row.values, bound.preds)) continue;
        try emitRow(gpa, &owned_text, &cells, projection, row.values);
        emitted += 1;
    }
    return .{ .columns = columns, .cells = try cells.toOwnedSlice(gpa), .owned_text = owned_text, .gpa = gpa };
}

/// Execute a read-only Request over a document collection. Each emitted field
/// is a dotted path resolved against the document (absent path reads as null);
/// each `where` predicate evaluates the same way, so a predicate on an absent
/// or differently typed field does not match that document. Reads follow the
/// collection's insertion order, matching the relation slice's read order.
fn executeDocument(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, opts: ExecOptions) ExecError!Result {
    const collection = eng.getDocumentCollection(request.relation) orelse return error.SemanticNameNotFound;
    const projection = request.fields;
    var owned_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_text.items) |text| gpa.free(text);
        owned_text.deinit(gpa);
    }
    const columns = try gpa.alloc([]const u8, projection.len);
    errdefer gpa.free(columns);
    for (projection, 0..) |path, index| {
        columns[index] = try ownColumn(gpa, &owned_text, path);
    }

    var bound = try bindDocumentWhere(gpa, request.where);
    defer bound.deinit();

    var cells: std.ArrayList([]?[]const u8) = .empty;
    errdefer {
        for (cells.items) |row| gpa.free(row);
        cells.deinit(gpa);
    }

    const pred_values = try gpa.alloc(value.Value, request.where.len);
    defer gpa.free(pred_values);
    const max_rows: usize = if (request.limit) |limit| @intCast(limit) else std.math.maxInt(usize);
    var emitted: usize = 0;
    for (collection.order.items) |doc| {
        if (emitted >= max_rows) break;
        try checkCancel(opts);
        for (request.where, 0..) |*predicate, index| {
            pred_values[index] = doc.pathValue(predicate.column) orelse .null;
        }
        if (!table_mod.valuesMatch(pred_values, bound.preds)) continue;
        const row = try gpa.alloc(?[]const u8, projection.len);
        errdefer gpa.free(row);
        for (projection, 0..) |path, index| {
            row[index] = try valueToText(gpa, &owned_text, doc.pathValue(path) orelse .null);
        }
        try cells.append(gpa, row);
        emitted += 1;
    }
    return .{ .columns = columns, .cells = try cells.toOwnedSlice(gpa), .owned_text = owned_text, .gpa = gpa };
}

/// Execute a read-only Request through an explicit transaction with Read
/// Committed visibility: a relation `emit` sees committed state merged with the
/// transaction's private write set (read-your-writes). Each Request re-reads
/// the latest committed state, so two `emit` calls in one explicit transaction
/// may observe commits made by other transactions between them. The evidence
/// view has no private write set in this slice and is read from committed
/// observations directly.
pub fn executeTx(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, tx: *txn_mod.Transaction) ExecError!Result {
    return executeTxOpts(gpa, eng, request, tx, .{});
}

/// Transaction-scoped execution with the same optional cancellation probe as
/// `executeOpts`.
pub fn executeTxOpts(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, tx: *txn_mod.Transaction, opts: ExecOptions) ExecError!Result {
    if (request.model_revision != ir.DEVELOPMENT_MODEL_REVISION) return error.ModelRevisionMismatch;
    if (request.operation != .emit) return error.InvalidOperation;
    if (std.mem.eql(u8, request.relation, "observation_evidence")) return executeEvidence(gpa, eng, request, opts);
    // Document and graph collections have no private write set in this slice;
    // they are read from committed state exactly as outside a transaction.
    if (eng.getDocumentCollection(request.relation)) |_| {
        if (request.navigate != null) return error.UnsupportedNavigate;
        return executeDocument(gpa, eng, request, opts);
    }
    if (eng.getGraph(request.relation) != null) return executeGraph(gpa, eng, request, opts);
    const table = eng.getTable(request.relation) orelse return error.SemanticNameNotFound;
    if (request.navigate != null) return error.UnsupportedNavigate;
    const projection = try bindProjection(gpa, table, request.fields);
    defer gpa.free(projection);

    var owned_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_text.items) |text| gpa.free(text);
        owned_text.deinit(gpa);
    }
    const columns = try gpa.alloc([]const u8, projection.len);
    errdefer gpa.free(columns);
    for (projection, 0..) |index, output_index| {
        columns[output_index] = try ownColumn(gpa, &owned_text, table.columns[index].name);
    }
    var cells: std.ArrayList([]?[]const u8) = .empty;
    errdefer {
        for (cells.items) |row| gpa.free(row);
        cells.deinit(gpa);
    }

    var bound = try bindTableWhere(gpa, table, request.where);
    defer bound.deinit();

    // Read Committed: each statement in an explicit transaction takes a fresh
    // published watermark, so it observes commits made by other transactions
    // between statements while still merging its own private write set. The
    // engine's snapshot-aware scan registers the watermark for the read.
    const snapshot_seq = eng.publishedSeq();
    var merged = eng.selectAllTx(tx, request.relation, snapshot_seq) catch |err| return switch (err) {
        error.TableNotFound => error.SemanticNameNotFound,
        error.SnapshotLimitExceeded => error.OutOfMemory,
        error.OutOfMemory => error.OutOfMemory,
    };
    defer merged.deinit();

    const max_rows: usize = if (request.limit) |limit| @intCast(limit) else std.math.maxInt(usize);
    var emitted: usize = 0;
    for (merged.rows) |row| {
        if (emitted >= max_rows) break;
        try checkCancel(opts);
        if (!table_mod.valuesMatch(row.values, bound.preds)) continue;
        try emitRow(gpa, &owned_text, &cells, projection, row.values);
        emitted += 1;
    }
    return .{ .columns = columns, .cells = try cells.toOwnedSlice(gpa), .owned_text = owned_text, .gpa = gpa };
}

/// Project one row's values into an output cell row and append it to `cells`.
/// Text rendering is owned through `owned_text`; the caller frees both.
fn emitRow(gpa: Allocator, owned_text: *std.ArrayList([]u8), cells: *std.ArrayList([]?[]const u8), projection: []const usize, row_values: []const value.Value) !void {
    const output = try gpa.alloc(?[]const u8, projection.len);
    errdefer gpa.free(output);
    for (projection, 0..) |column, output_index| {
        output[output_index] = try valueToText(gpa, owned_text, row_values[column]);
    }
    try cells.append(gpa, output);
}

const EvidenceField = struct {
    name: []const u8,
    type_tag: value.TypeTag,
};

const evidence_fields = [_]EvidenceField{
    .{ .name = "evidence_id", .type_tag = .int },
    .{ .name = "object_id", .type_tag = .text },
    .{ .name = "modality", .type_tag = .text },
    .{ .name = "media_type", .type_tag = .text },
    .{ .name = "observed_at", .type_tag = .text },
    .{ .name = "origin", .type_tag = .text },
    .{ .name = "owner", .type_tag = .text },
    .{ .name = "payload_length", .type_tag = .int },
    .{ .name = "payload_digest", .type_tag = .text },
};

fn executeEvidence(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, opts: ExecOptions) !Result {
    const projection = try gpa.alloc(usize, request.fields.len);
    defer gpa.free(projection);
    for (request.fields, 0..) |field, output_index| {
        projection[output_index] = evidenceFieldIndex(field) orelse return error.FieldNotFound;
    }
    var owned_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_text.items) |text| gpa.free(text);
        owned_text.deinit(gpa);
    }
    const columns = try gpa.alloc([]const u8, request.fields.len);
    errdefer gpa.free(columns);
    for (projection, 0..) |field_index, index| {
        columns[index] = try ownColumn(gpa, &owned_text, evidence_fields[field_index].name);
    }
    var cells: std.ArrayList([]?[]const u8) = .empty;
    errdefer {
        for (cells.items) |row| gpa.free(row);
        cells.deinit(gpa);
    }

    var bound = try bindEvidenceWhere(gpa, request.where);
    defer bound.deinit();

    const observations = eng.observationsView();
    var digest_hex: [2 * evidence.DIGEST_LENGTH]u8 = undefined;
    var values_buf: [evidence_fields.len]value.Value = undefined;
    const max_rows: usize = if (request.limit) |limit| @intCast(limit) else std.math.maxInt(usize);
    var emitted: usize = 0;
    for (observations) |record| {
        if (emitted >= max_rows) break;
        try checkCancel(opts);
        for (0..values_buf.len) |field_index| values_buf[field_index] = evidenceValue(&record, field_index, &digest_hex);
        if (!table_mod.valuesMatch(&values_buf, bound.preds)) continue;
        const row = try gpa.alloc(?[]const u8, projection.len);
        errdefer gpa.free(row);
        for (projection, 0..) |field_index, output_index| {
            row[output_index] = switch (field_index) {
                0 => try ownedFormat(gpa, &owned_text, "{d}", .{record.evidence_id}),
                1 => record.object_id,
                2 => @tagName(record.modality),
                3 => record.media_type,
                4 => record.observed_at,
                5 => record.origin,
                6 => record.owner,
                7 => try ownedFormat(gpa, &owned_text, "{d}", .{record.payload_length}),
                8 => blk: {
                    const hex = std.fmt.bytesToHex(record.payload_digest, .lower);
                    const text = try gpa.dupe(u8, &hex);
                    try owned_text.append(gpa, text);
                    break :blk text;
                },
                else => unreachable,
            };
        }
        try cells.append(gpa, row);
        emitted += 1;
    }
    return .{ .columns = columns, .cells = try cells.toOwnedSlice(gpa), .owned_text = owned_text, .gpa = gpa };
}

/// Extract a borrowed typed value for one evidence field. The digest hex is
/// written into `digest_hex`, which must outlive the returned value.
fn evidenceValue(record: *const evidence.Record, field_index: usize, digest_hex: *[2 * evidence.DIGEST_LENGTH]u8) value.Value {
    return switch (field_index) {
        0 => .{ .int = @intCast(record.evidence_id) },
        1 => .{ .text = record.object_id },
        2 => .{ .text = @constCast(@tagName(record.modality)) },
        3 => .{ .text = record.media_type },
        4 => .{ .text = record.observed_at },
        5 => .{ .text = record.origin },
        6 => .{ .text = record.owner },
        7 => .{ .int = @intCast(record.payload_length) },
        8 => blk: {
            const hex = std.fmt.bytesToHex(record.payload_digest, .lower);
            @memcpy(digest_hex, &hex);
            break :blk .{ .text = digest_hex[0..] };
        },
        else => unreachable,
    };
}

fn evidenceFieldIndex(name: []const u8) ?usize {
    for (evidence_fields, 0..) |field, index| {
        if (std.mem.eql(u8, name, field.name)) return index;
    }
    return null;
}

fn ownedFormat(gpa: Allocator, owned: *std.ArrayList([]u8), comptime format: []const u8, args: anytype) ![]const u8 {
    const text = try std.fmt.allocPrint(gpa, format, args);
    errdefer gpa.free(text);
    try owned.append(gpa, text);
    return text;
}

fn bindProjection(gpa: Allocator, table: *engine_mod.Table, fields: []const []u8) ![]usize {
    const projection = try gpa.alloc(usize, fields.len);
    errdefer gpa.free(projection);
    for (fields, 0..) |field, field_index| {
        for (table.columns, 0..) |column, column_index| {
            if (std.mem.eql(u8, field, column.name)) {
                projection[field_index] = column_index;
                break;
            }
        } else return error.FieldNotFound;
    }
    return projection;
}

/// Bound predicates plus the value arrays allocated for `in` lists. Text
/// literals are borrowed from the Request and need no ownership here.
const BoundWhere = struct {
    gpa: Allocator,
    preds: []table_mod.Pred,
    owned: std.ArrayList([]value.Value) = .empty,

    fn deinit(self: *BoundWhere) void {
        for (self.owned.items) |values| self.gpa.free(values);
        self.owned.deinit(self.gpa);
        self.gpa.free(self.preds);
    }
};

fn bindTableWhere(gpa: Allocator, table: *engine_mod.Table, predicates: []const ast.Predicate) !BoundWhere {
    const preds = try gpa.alloc(table_mod.Pred, predicates.len);
    errdefer gpa.free(preds);
    var owned: std.ArrayList([]value.Value) = .empty;
    errdefer {
        for (owned.items) |values| gpa.free(values);
        owned.deinit(gpa);
    }
    for (predicates, 0..) |*predicate, index| {
        const column_index = table.columnIndex(predicate.column) orelse return error.FieldNotFound;
        preds[index] = try buildPred(gpa, column_index, table.columns[column_index].type_tag, predicate, &owned);
    }
    return .{ .gpa = gpa, .preds = preds, .owned = owned };
}

fn bindEvidenceWhere(gpa: Allocator, predicates: []const ast.Predicate) !BoundWhere {
    const preds = try gpa.alloc(table_mod.Pred, predicates.len);
    errdefer gpa.free(preds);
    var owned: std.ArrayList([]value.Value) = .empty;
    errdefer {
        for (owned.items) |values| gpa.free(values);
        owned.deinit(gpa);
    }
    for (predicates, 0..) |*predicate, index| {
        const field_index = evidenceFieldIndex(predicate.column) orelse return error.FieldNotFound;
        preds[index] = try buildPred(gpa, field_index, evidence_fields[field_index].type_tag, predicate, &owned);
    }
    return .{ .gpa = gpa, .preds = preds, .owned = owned };
}

/// Execute a read-only Request over a graph. Without `navigate`, nodes read
/// like documents. With `navigate`, every surviving source node is expanded
/// into one row per outgoing edge carrying `edge.label`; the destination node
/// is addressable through `alias.<path>` in the emit, while unqualified paths
/// resolve against the source node. A node with no matching outgoing edge
/// produces no row.
fn executeGraph(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, opts: ExecOptions) ExecError!Result {
    const graph = eng.getGraph(request.relation) orelse return error.SemanticNameNotFound;
    const navigate = request.navigate;

    const projection = request.fields;
    var owned_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_text.items) |text| gpa.free(text);
        owned_text.deinit(gpa);
    }
    const columns = try gpa.alloc([]const u8, projection.len);
    errdefer gpa.free(columns);
    for (projection, 0..) |path, index| {
        columns[index] = try ownColumn(gpa, &owned_text, path);
    }

    var bound = try bindDocumentWhere(gpa, request.where);
    defer bound.deinit();

    var cells: std.ArrayList([]?[]const u8) = .empty;
    errdefer {
        for (cells.items) |row| gpa.free(row);
        cells.deinit(gpa);
    }

    const pred_values = try gpa.alloc(value.Value, request.where.len);
    defer gpa.free(pred_values);
    const max_rows: usize = if (request.limit) |limit| @intCast(limit) else std.math.maxInt(usize);
    var emitted: usize = 0;

    if (navigate) |nav| {
        for (graph.nodes.order.items) |source| {
            if (emitted >= max_rows) break;
            try checkCancel(opts);
            for (request.where, 0..) |*predicate, index| pred_values[index] = source.pathValue(predicate.column) orelse .null;
            if (!table_mod.valuesMatch(pred_values, bound.preds)) continue;
            for (graph.edges.items) |*edge_item| {
                if (emitted >= max_rows) break;
                try checkCancel(opts);
                if (!std.mem.eql(u8, edge_item.from, source.id) or !std.mem.eql(u8, edge_item.label, nav.edge)) continue;
                const dest = graph.nodes.by_id.get(edge_item.to) orelse continue;
                const row = try gpa.alloc(?[]const u8, projection.len);
                errdefer gpa.free(row);
                for (projection, 0..) |path, index| {
                    const item = graphPathValue(nav.alias, source, dest, path);
                    row[index] = try valueToText(gpa, &owned_text, item orelse .null);
                }
                try cells.append(gpa, row);
                emitted += 1;
            }
        }
    } else {
        for (graph.nodes.order.items) |node| {
            if (emitted >= max_rows) break;
            try checkCancel(opts);
            for (request.where, 0..) |*predicate, index| pred_values[index] = node.pathValue(predicate.column) orelse .null;
            if (!table_mod.valuesMatch(pred_values, bound.preds)) continue;
            const row = try gpa.alloc(?[]const u8, projection.len);
            errdefer gpa.free(row);
            for (projection, 0..) |path, index| {
                row[index] = try valueToText(gpa, &owned_text, node.pathValue(path) orelse .null);
            }
            try cells.append(gpa, row);
            emitted += 1;
        }
    }
    return .{ .columns = columns, .cells = try cells.toOwnedSlice(gpa), .owned_text = owned_text, .gpa = gpa };
}

/// Resolve an emit path against a navigate row: `alias.<path>` reads the
/// destination node, any other path reads the source node.
fn graphPathValue(alias: []const u8, source: *const document_mod.Document, dest: *const document_mod.Document, path: []const u8) ?value.Value {
    if (std.mem.startsWith(u8, path, alias) and path.len > alias.len and path[alias.len] == '.') {
        return dest.pathValue(path[alias.len + 1 ..]);
    }
    return source.pathValue(path);
}

/// Bound predicates for a document collection. Predicate `col_index` is the
/// predicate's position; `executeDocument` fills a per-document value array at
/// those positions. `owned` holds the allocated `in`-list value arrays.
const BoundDocumentWhere = struct {
    gpa: Allocator,
    preds: []table_mod.Pred,
    owned: std.ArrayList([]value.Value) = .empty,

    fn deinit(self: *BoundDocumentWhere) void {
        for (self.owned.items) |values| self.gpa.free(values);
        self.owned.deinit(self.gpa);
        self.gpa.free(self.preds);
    }
};

/// Bind document predicates without a declared column type: documents are
/// variable-shape, so the literal keeps its own type and a predicate matches
/// only a same-typed field value (`valuesMatch` treats a type mismatch as a
/// non-match, exactly like an absent field reads as null).
fn bindDocumentWhere(gpa: Allocator, predicates: []const ast.Predicate) !BoundDocumentWhere {
    const preds = try gpa.alloc(table_mod.Pred, predicates.len);
    errdefer gpa.free(preds);
    var owned: std.ArrayList([]value.Value) = .empty;
    errdefer {
        for (owned.items) |values| gpa.free(values);
        owned.deinit(gpa);
    }
    for (predicates, 0..) |*predicate, index| {
        switch (predicate.op) {
            .is_null => preds[index] = .{ .is_null = .{ .col_index = index, .negated = false } },
            .not_null => preds[index] = .{ .is_null = .{ .col_index = index, .negated = true } },
            .in, .not_in => {
                const values = try gpa.alloc(value.Value, predicate.list.items.len);
                errdefer gpa.free(values);
                for (predicate.list.items, 0..) |*literal, literal_index| {
                    values[literal_index] = literalToBorrowedValue(literal.*);
                }
                try owned.append(gpa, values);
                preds[index] = .{ .in_list = .{ .col_index = index, .values = values, .negated = predicate.op == .not_in } };
            },
            .like, .not_like => {
                preds[index] = .{ .like = .{ .col_index = index, .pattern = literalToBorrowedValue(predicate.scalar.?), .negated = predicate.op == .not_like } };
            },
            else => {
                const literal = literalToBorrowedValue(predicate.scalar.?);
                preds[index] = switch (predicate.op) {
                    .eq => .{ .eq = .{ .col_index = index, .value = literal } },
                    .neq, .lt, .gt, .lte, .gte => .{ .cmp = .{
                        .col_index = index,
                        .op = switch (predicate.op) {
                            .neq => .neq,
                            .lt => .lt,
                            .gt => .gt,
                            .lte => .lte,
                            .gte => .gte,
                            else => unreachable,
                        },
                        .value = literal,
                    } },
                    else => unreachable,
                };
            },
        }
    }
    return .{ .gpa = gpa, .preds = preds, .owned = owned };
}

/// Convert a Flow literal to a borrowed scalar value. Text is borrowed from the
/// Request, which outlives the match; no allocation or type coercion occurs.
fn literalToBorrowedValue(literal: ast.Literal) value.Value {
    return switch (literal) {
        .int => |integer| .{ .int = integer },
        .bool => |boolean| .{ .bool = boolean },
        .text => |text| .{ .text = text },
    };
}

fn buildPred(gpa: Allocator, column_index: usize, column_type: value.TypeTag, predicate: *const ast.Predicate, owned: *std.ArrayList([]value.Value)) !table_mod.Pred {
    switch (predicate.op) {
        .is_null => return .{ .is_null = .{ .col_index = column_index, .negated = false } },
        .not_null => return .{ .is_null = .{ .col_index = column_index, .negated = true } },
        .in, .not_in => {
            const values = try gpa.alloc(value.Value, predicate.list.items.len);
            errdefer gpa.free(values);
            for (predicate.list.items, 0..) |*literal, index| values[index] = try literalToValue(column_type, literal);
            try owned.append(gpa, values);
            return .{ .in_list = .{ .col_index = column_index, .values = values, .negated = predicate.op == .not_in } };
        },
        .like, .not_like => {
            if (column_type != .text) return error.TypeMismatch;
            return .{ .like = .{ .col_index = column_index, .pattern = try literalToValue(.text, &predicate.scalar.?), .negated = predicate.op == .not_like } };
        },
        .eq, .neq, .lt, .gt, .lte, .gte => {
            switch (predicate.op) {
                .neq, .lt, .gt, .lte, .gte => if (column_type != .int and column_type != .text) return error.NonComparableColumn,
                else => {},
            }
            const literal = try literalToValue(column_type, &predicate.scalar.?);
            return switch (predicate.op) {
                .eq => .{ .eq = .{ .col_index = column_index, .value = literal } },
                .neq => .{ .cmp = .{ .col_index = column_index, .op = .neq, .value = literal } },
                .lt => .{ .cmp = .{ .col_index = column_index, .op = .lt, .value = literal } },
                .gt => .{ .cmp = .{ .col_index = column_index, .op = .gt, .value = literal } },
                .lte => .{ .cmp = .{ .col_index = column_index, .op = .lte, .value = literal } },
                .gte => .{ .cmp = .{ .col_index = column_index, .op = .gte, .value = literal } },
                else => unreachable,
            };
        },
    }
}

/// Coerce a literal to a column type, rejecting mismatches before execution.
/// Text bytes are borrowed from the Request and outlive the match.
fn literalToValue(column_type: value.TypeTag, literal: *const ast.Literal) !value.Value {
    return switch (literal.*) {
        .int => |integer| blk: {
            if (column_type != .int) return error.TypeMismatch;
            break :blk .{ .int = integer };
        },
        .bool => |boolean| blk: {
            if (column_type != .bool) return error.TypeMismatch;
            break :blk .{ .bool = boolean };
        },
        .text => |text| blk: {
            if (column_type != .text) return error.TypeMismatch;
            break :blk .{ .text = text };
        },
    };
}

fn valueToText(gpa: Allocator, owned: *std.ArrayList([]u8), item: value.Value) !?[]const u8 {
    switch (item) {
        .null => return null,
        // Text is copied into `owned` so a rendered row never aliases the
        // source row: the relation emit path may read through a transient
        // transaction write set whose rows are freed when the read completes.
        .text => |text| {
            const owned_text = try gpa.dupe(u8, text);
            owned.append(gpa, owned_text) catch |err| {
                gpa.free(owned_text);
                return err;
            };
            return owned_text;
        },
        .bool => |boolean| return if (boolean) "true" else "false",
        .int => |integer| {
            const text = try std.fmt.allocPrint(gpa, "{d}", .{integer});
            try owned.append(gpa, text);
            return text;
        },
        .vector => |items| {
            var text: std.ArrayList(u8) = .empty;
            errdefer text.deinit(gpa);
            try text.append(gpa, '[');
            for (items, 0..) |component, index| {
                if (index != 0) try text.append(gpa, ',');
                const component_text = try std.fmt.allocPrint(gpa, "{d}", .{component});
                defer gpa.free(component_text);
                try text.appendSlice(gpa, component_text);
            }
            try text.append(gpa, ']');
            const rendered = try text.toOwnedSlice(gpa);
            try owned.append(gpa, rendered);
            return rendered;
        },
    }
}

test "executes a read-only relation flow" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-exec";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try std.testing.allocator.dupe(u8, "name"), .type_tag = .text },
    };
    defer for (&columns) |*column| column.deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    var name: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "Ada") };
    defer name.deinit(std.testing.allocator);
    try eng.insert("customer", &.{ .{ .int = 1 }, name });
    var request = try compile(std.testing.allocator, "from customer\n| emit { name, id }");
    defer request.deinit(std.testing.allocator);
    var result = try execute(std.testing.allocator, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqualStrings("name", result.columns[0]);
    try std.testing.expectEqualStrings("Ada", result.cells[0][0].?);
}

test "limit bounds relation results" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-limit";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{.{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int }};
    defer columns[0].deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    try eng.insert("customer", &.{.{ .int = 1 }});
    try eng.insert("customer", &.{.{ .int = 2 }});
    var request = try compile(std.testing.allocator, "from customer\n| emit { id }\n| limit 1");
    defer request.deinit(std.testing.allocator);
    var result = try execute(std.testing.allocator, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);

    var zero_request = try compile(std.testing.allocator, "from customer\n| emit { id }\n| limit 0");
    defer zero_request.deinit(std.testing.allocator);
    var zero_result = try execute(std.testing.allocator, &eng, &zero_request);
    defer zero_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), zero_result.cells.len);
}

test "limit bounds observation evidence results" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-evidence-limit";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    _ = try eng.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "test-camera", "development", "first");
    _ = try eng.observe("camera_2", .image, "image/png", "2026-07-31T12:01:00+08:00", "test-camera", "development", "second");
    var request = try compile(std.testing.allocator, "from observation_evidence\n| emit { object_id }\n| limit 1");
    defer request.deinit(std.testing.allocator);
    var result = try execute(std.testing.allocator, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);
    try std.testing.expectEqualStrings("camera_1", result.cells[0][0].?);
}

test "renders an embedding projection as a vector literal" {
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |text| std.testing.allocator.free(text);
        owned.deinit(std.testing.allocator);
    }
    var embedding: value.Value = .{ .vector = try std.testing.allocator.dupe(f32, &.{ 1, 2.5 }) };
    defer embedding.deinit(std.testing.allocator);
    const rendered = (try valueToText(std.testing.allocator, &owned, embedding)).?;
    try std.testing.expectEqualStrings("[1,2.5]", rendered);
}

test "where filters a relation before projection and limit" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-where";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try std.testing.allocator.dupe(u8, "region"), .type_tag = .text },
        .{ .name = try std.testing.allocator.dupe(u8, "score"), .type_tag = .int },
    };
    defer for (&columns) |*column| column.deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    var north: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "north") };
    defer north.deinit(std.testing.allocator);
    var south: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "south") };
    defer south.deinit(std.testing.allocator);
    try eng.insert("customer", &.{ .{ .int = 1 }, north, .{ .int = 30 } });
    try eng.insert("customer", &.{ .{ .int = 2 }, south, .{ .int = 10 } });
    try eng.insert("customer", &.{ .{ .int = 3 }, north, .{ .int = 40 } });

    var request = try compile(std.testing.allocator, "from customer\n| where region = 'north'\n| where score > 25\n| emit { id }\n| limit 1");
    defer request.deinit(std.testing.allocator);
    var result = try execute(std.testing.allocator, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);
    try std.testing.expectEqualStrings("1", result.cells[0][0].?);
}

test "where supports membership, null, and pattern predicates" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-where-ops";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try std.testing.allocator.dupe(u8, "name"), .type_tag = .text },
        .{ .name = try std.testing.allocator.dupe(u8, "region"), .type_tag = .text },
        .{ .name = try std.testing.allocator.dupe(u8, "active"), .type_tag = .bool },
    };
    defer for (&columns) |*column| column.deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    var ada: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "ada") };
    defer ada.deinit(std.testing.allocator);
    var bob: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "bob") };
    defer bob.deinit(std.testing.allocator);
    var ann: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "ann") };
    defer ann.deinit(std.testing.allocator);
    var north: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "north") };
    defer north.deinit(std.testing.allocator);
    try eng.insert("customer", &.{ .{ .int = 1 }, ada, .null, .{ .bool = true } });
    try eng.insert("customer", &.{ .{ .int = 2 }, bob, north, .{ .bool = false } });
    try eng.insert("customer", &.{ .{ .int = 3 }, ann, north, .{ .bool = true } });

    var membership = try compile(std.testing.allocator, "from customer\n| where id in (1, 3)\n| emit { id }");
    defer membership.deinit(std.testing.allocator);
    var membership_result = try execute(std.testing.allocator, &eng, &membership);
    defer membership_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), membership_result.cells.len);
    try std.testing.expectEqualStrings("1", membership_result.cells[0][0].?);
    try std.testing.expectEqualStrings("3", membership_result.cells[1][0].?);

    var not_in = try compile(std.testing.allocator, "from customer\n| where id not in (1, 2)\n| emit { id }");
    defer not_in.deinit(std.testing.allocator);
    var not_in_result = try execute(std.testing.allocator, &eng, &not_in);
    defer not_in_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), not_in_result.cells.len);

    var nulls = try compile(std.testing.allocator, "from customer\n| where region is null\n| emit { id }");
    defer nulls.deinit(std.testing.allocator);
    var nulls_result = try execute(std.testing.allocator, &eng, &nulls);
    defer nulls_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), nulls_result.cells.len);
    try std.testing.expectEqualStrings("1", nulls_result.cells[0][0].?);

    var patterned = try compile(std.testing.allocator, "from customer\n| where name like 'a%'\n| emit { name }");
    defer patterned.deinit(std.testing.allocator);
    var patterned_result = try execute(std.testing.allocator, &eng, &patterned);
    defer patterned_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), patterned_result.cells.len);

    var boolean = try compile(std.testing.allocator, "from customer\n| where active = true\n| where name != 'bob'\n| emit { id }");
    defer boolean.deinit(std.testing.allocator);
    var boolean_result = try execute(std.testing.allocator, &eng, &boolean);
    defer boolean_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), boolean_result.cells.len);
}

test "where filters observation evidence by typed fields" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-where-evidence";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    _ = try eng.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "test-camera", "development", "first payload");
    _ = try eng.observe("camera_2", .audio, "audio/ogg", "2026-07-31T12:01:00+08:00", "test-mic", "development", "second payload");

    var by_object = try compile(std.testing.allocator, "from observation_evidence\n| where object_id = 'camera_2'\n| emit { evidence_id, modality }\n| limit 1");
    defer by_object.deinit(std.testing.allocator);
    var by_object_result = try execute(std.testing.allocator, &eng, &by_object);
    defer by_object_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), by_object_result.cells.len);
    try std.testing.expectEqualStrings("audio", by_object_result.cells[0][1].?);

    var by_id = try compile(std.testing.allocator, "from observation_evidence\n| where evidence_id = 1\n| emit { object_id }\n| limit 1");
    defer by_id.deinit(std.testing.allocator);
    var by_id_result = try execute(std.testing.allocator, &eng, &by_id);
    defer by_id_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), by_id_result.cells.len);
    try std.testing.expectEqualStrings("camera_1", by_id_result.cells[0][0].?);

    var by_length = try compile(std.testing.allocator, "from observation_evidence\n| where payload_length >= 14\n| emit { object_id }\n| limit 1");
    defer by_length.deinit(std.testing.allocator);
    var by_length_result = try execute(std.testing.allocator, &eng, &by_length);
    defer by_length_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), by_length_result.cells.len);
    try std.testing.expectEqualStrings("camera_2", by_length_result.cells[0][0].?);
}

test "emit through a transaction reads its own staged writes" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-exec-tx";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try std.testing.allocator.dupe(u8, "name"), .type_tag = .text },
    };
    defer for (&columns) |*column| column.deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    var ada: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "Ada") };
    defer ada.deinit(std.testing.allocator);
    try eng.insert("customer", &.{ .{ .int = 1 }, ada });

    var tx = eng.beginTransaction();
    defer tx.deinit();
    var grace: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "Grace") };
    defer grace.deinit(std.testing.allocator);
    try eng.stageInsert(&tx, "customer", &.{ .{ .int = 2 }, grace });

    // Without the transaction, only committed rows are visible.
    var plain_request = try compile(std.testing.allocator, "from customer\n| emit { id, name }");
    defer plain_request.deinit(std.testing.allocator);
    var plain = try execute(std.testing.allocator, &eng, &plain_request);
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 1), plain.cells.len);

    // Through the transaction, the staged row is visible too.
    var tx_request = try compile(std.testing.allocator, "from customer\n| emit { id, name }");
    defer tx_request.deinit(std.testing.allocator);
    var result = try executeTx(std.testing.allocator, &eng, &tx_request, &tx);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.cells.len);
    try std.testing.expectEqualStrings("2", result.cells[1][0].?);
    try std.testing.expectEqualStrings("Grace", result.cells[1][1].?);
}

test "emit through a transaction applies where over merged rows" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-exec-tx-where";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try std.testing.allocator.dupe(u8, "region"), .type_tag = .text },
    };
    defer for (&columns) |*column| column.deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    var north: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "north") };
    defer north.deinit(std.testing.allocator);
    var south: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "south") };
    defer south.deinit(std.testing.allocator);
    try eng.insert("customer", &.{ .{ .int = 1 }, north });

    var tx = eng.beginTransaction();
    defer tx.deinit();
    try eng.stageInsert(&tx, "customer", &.{ .{ .int = 2 }, south });

    // A predicate is evaluated against the merged row set: the staged row is
    // filtered like any committed row.
    var request = try compile(std.testing.allocator, "from customer\n| where region = 'south'\n| emit { id }");
    defer request.deinit(std.testing.allocator);
    var result = try executeTx(std.testing.allocator, &eng, &request, &tx);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);
    try std.testing.expectEqualStrings("2", result.cells[0][0].?);
}

test "where binding rejects unknown columns and type mismatches" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-where-errors";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try std.testing.allocator.dupe(u8, "name"), .type_tag = .text },
        .{ .name = try std.testing.allocator.dupe(u8, "active"), .type_tag = .bool },
    };
    defer for (&columns) |*column| column.deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    var ada: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "ada") };
    defer ada.deinit(std.testing.allocator);
    try eng.insert("customer", &.{ .{ .int = 1 }, ada, .{ .bool = true } });

    var unknown = try compile(std.testing.allocator, "from customer\n| where missing = 1\n| emit { id }");
    defer unknown.deinit(std.testing.allocator);
    try std.testing.expectError(error.FieldNotFound, execute(std.testing.allocator, &eng, &unknown));

    var mismatch = try compile(std.testing.allocator, "from customer\n| where id = 'x'\n| emit { id }");
    defer mismatch.deinit(std.testing.allocator);
    try std.testing.expectError(error.TypeMismatch, execute(std.testing.allocator, &eng, &mismatch));

    var comparable = try compile(std.testing.allocator, "from customer\n| where active > true\n| emit { id }");
    defer comparable.deinit(std.testing.allocator);
    try std.testing.expectError(error.NonComparableColumn, execute(std.testing.allocator, &eng, &comparable));

    var pattern_type = try compile(std.testing.allocator, "from customer\n| where id like '1%'\n| emit { id }");
    defer pattern_type.deinit(std.testing.allocator);
    try std.testing.expectError(error.TypeMismatch, execute(std.testing.allocator, &eng, &pattern_type));
}

test "dotted paths parse and bind as identifier paths" {
    const gpa = std.testing.allocator;
    var parsed = try ast.parse(gpa, "from customer\n| where author.name = 'ada'\n| where title like 'a%'\n| emit { author.name, title }\n| limit 5");
    defer parsed.deinit(gpa);
    try std.testing.expectEqualStrings("author.name", parsed.where[0].column);
    try std.testing.expectEqualStrings("title", parsed.where[1].column);
    try std.testing.expectEqualStrings("author.name", parsed.fields[0]);
    try std.testing.expectEqual(@as(?u32, 5), parsed.limit);

    // The canonical IR accepts the dotted-path shape; a trailing dot or empty
    // segment is rejected as an identifier.
    var request = try ir.bind(gpa, parsed);
    defer request.deinit(gpa);
    try std.testing.expectEqualStrings("author.name", request.fields[0]);

    try std.testing.expect(!ast.isPath("author."));
    try std.testing.expect(!ast.isPath("author..name"));
    try std.testing.expect(!ast.isPath(".name"));
    try std.testing.expect(ast.isPath("author.name"));
    try std.testing.expect(ast.isPath("id"));
}

test "source and equivalent canonical IR produce the same result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-ir-equivalence";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text },
        .{ .name = try gpa.dupe(u8, "region"), .type_tag = .text },
    };
    defer for (&columns) |*column| column.deinit(gpa);
    try eng.createTable("customer", &columns);
    var ada: value.Value = .{ .text = try gpa.dupe(u8, "ada") };
    defer ada.deinit(gpa);
    var ann: value.Value = .{ .text = try gpa.dupe(u8, "ann") };
    defer ann.deinit(gpa);
    var north: value.Value = .{ .text = try gpa.dupe(u8, "north") };
    defer north.deinit(gpa);
    var south: value.Value = .{ .text = try gpa.dupe(u8, "south") };
    defer south.deinit(gpa);
    try eng.insert("customer", &.{ .{ .int = 1 }, ada, north });
    try eng.insert("customer", &.{ .{ .int = 2 }, ann, north });
    try eng.insert("customer", &.{ .{ .int = 3 }, ann, south });

    const source = "from customer\n| where region = 'north'\n| emit { id, name }\n| limit 10";

    // Execute the bound source request directly...
    var request_a = try compile(gpa, source);
    defer request_a.deinit(gpa);
    var result_a = try execute(gpa, &eng, &request_a);
    defer result_a.deinit();

    // ...then execute the identical request recovered from its canonical IR
    // bytes, exactly as the Wire Protocol's FLOW_IR path would.
    const bytes = try ir.encode(gpa, &request_a);
    defer gpa.free(bytes);
    var request_b = try ir.decode(gpa, bytes);
    defer request_b.deinit(gpa);
    var result_b = try execute(gpa, &eng, &request_b);
    defer result_b.deinit();

    try std.testing.expectEqual(result_a.columns.len, result_b.columns.len);
    try std.testing.expectEqual(result_a.cells.len, result_b.cells.len);
    for (result_a.columns, 0..) |column, index| try std.testing.expectEqualStrings(column, result_b.columns[index]);
    for (result_a.cells, 0..) |row, row_index| {
        for (row, 0..) |cell, col_index| {
            try std.testing.expectEqualStrings(cell.?, result_b.cells[row_index][col_index].?);
        }
    }
}

test "source and equivalent IR produce the same error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-ir-error-equivalence";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
    defer columns[0].deinit(gpa);
    try eng.createTable("customer", &columns);

    // A source that names an unknown field fails binding; the equivalent IR
    // (encoded from the bound request, which only differs in that the source
    // already failed) must fail identically. Encoding a request whose field is
    // unknown at execution still round-trips; the failure is at execution.
    const source = "from customer\n| emit { missing }";
    var request_a = try compile(gpa, source);
    defer request_a.deinit(gpa);
    try std.testing.expectError(error.FieldNotFound, execute(gpa, &eng, &request_a));

    const bytes = try ir.encode(gpa, &request_a);
    defer gpa.free(bytes);
    var request_b = try ir.decode(gpa, bytes);
    defer request_b.deinit(gpa);
    try std.testing.expectError(error.FieldNotFound, execute(gpa, &eng, &request_b));

    // An unresolvable relation produces the same error from source and IR.
    const missing_rel = "from nobody\n| emit { id }";
    var rel_a = try compile(gpa, missing_rel);
    defer rel_a.deinit(gpa);
    try std.testing.expectError(error.SemanticNameNotFound, execute(gpa, &eng, &rel_a));
    const rel_bytes = try ir.encode(gpa, &rel_a);
    defer gpa.free(rel_bytes);
    var rel_b = try ir.decode(gpa, rel_bytes);
    defer rel_b.deinit(gpa);
    try std.testing.expectError(error.SemanticNameNotFound, execute(gpa, &eng, &rel_b));
}

// ── Document collection slice (roadmap Phase 2) ──

fn insertTestDocuments(gpa: Allocator, eng: *engine_mod.Engine) !void {
    try eng.createDocument("books");
    var dune: [3]document_mod.Field = undefined;
    dune[0] = .{ .path = try gpa.dupe(u8, "title"), .item = .{ .text = try gpa.dupe(u8, "Dune") } };
    dune[1] = .{ .path = try gpa.dupe(u8, "author.name"), .item = .{ .text = try gpa.dupe(u8, "Herbert") } };
    dune[2] = .{ .path = try gpa.dupe(u8, "pages"), .item = .{ .int = 412 } };
    defer for (&dune) |*f| f.deinit(gpa);
    try eng.insertDocument("books", "1", &dune);

    var snow: [3]document_mod.Field = undefined;
    snow[0] = .{ .path = try gpa.dupe(u8, "title"), .item = .{ .text = try gpa.dupe(u8, "Snow Crash") } };
    snow[1] = .{ .path = try gpa.dupe(u8, "author.name"), .item = .{ .text = try gpa.dupe(u8, "Stephenson") } };
    snow[2] = .{ .path = try gpa.dupe(u8, "pages"), .item = .{ .int = 480 } };
    defer for (&snow) |*f| f.deinit(gpa);
    try eng.insertDocument("books", "2", &snow);
}

test "reads a document collection with path projection and predicates" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-documents";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestDocuments(gpa, &eng);

    var request = try compile(gpa, "from books\n| where author.name = 'Herbert'\n| emit { title, author.name, pages }\n| limit 5");
    defer request.deinit(gpa);
    var result = try execute(gpa, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);
    try std.testing.expectEqualStrings("title", result.columns[0]);
    try std.testing.expectEqualStrings("author.name", result.columns[1]);
    try std.testing.expectEqualStrings("pages", result.columns[2]);
    try std.testing.expectEqualStrings("Dune", result.cells[0][0].?);
    try std.testing.expectEqualStrings("Herbert", result.cells[0][1].?);
    try std.testing.expectEqualStrings("412", result.cells[0][2].?);

    // Numeric predicate over a path; a path absent from a document reads null
    // and never matches.
    var pages = try compile(gpa, "from books\n| where pages >= 450\n| emit { title }");
    defer pages.deinit(gpa);
    var pages_result = try execute(gpa, &eng, &pages);
    defer pages_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), pages_result.cells.len);
    try std.testing.expectEqualStrings("Snow Crash", pages_result.cells[0][0].?);

    var absent = try compile(gpa, "from books\n| where genre = 'scifi'\n| emit { title, genre }");
    defer absent.deinit(gpa);
    var absent_result = try execute(gpa, &eng, &absent);
    defer absent_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), absent_result.cells.len);
}

test "document source and equivalent IR produce the same result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-document-ir";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestDocuments(gpa, &eng);

    const source = "from books\n| where pages > 400\n| emit { title, author.name }";
    var request_a = try compile(gpa, source);
    defer request_a.deinit(gpa);
    var result_a = try execute(gpa, &eng, &request_a);
    defer result_a.deinit();

    const bytes = try ir.encode(gpa, &request_a);
    defer gpa.free(bytes);
    var request_b = try ir.decode(gpa, bytes);
    defer request_b.deinit(gpa);
    var result_b = try execute(gpa, &eng, &request_b);
    defer result_b.deinit();

    try std.testing.expectEqual(result_a.cells.len, result_b.cells.len);
    try std.testing.expectEqual(@as(usize, 2), result_a.cells.len);
    for (result_a.cells, 0..) |row, i| {
        try std.testing.expectEqualStrings(row[0].?, result_b.cells[i][0].?);
        try std.testing.expectEqualStrings(row[1].?, result_b.cells[i][1].?);
    }
}

test "reading an unknown name still fails when a document collection exists" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-document-missing";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestDocuments(gpa, &eng);

    var request = try compile(gpa, "from nothing\n| emit { title }");
    defer request.deinit(gpa);
    try std.testing.expectError(error.SemanticNameNotFound, execute(gpa, &eng, &request));
}

fn insertTestGraph(gpa: Allocator, eng: *engine_mod.Engine) !void {
    var ada: [1]document_mod.Field = undefined;
    ada[0] = .{ .path = try gpa.dupe(u8, "name"), .item = .{ .text = try gpa.dupe(u8, "Ada") } };
    defer for (&ada) |*f| f.deinit(gpa);
    var grace: [1]document_mod.Field = undefined;
    grace[0] = .{ .path = try gpa.dupe(u8, "name"), .item = .{ .text = try gpa.dupe(u8, "Grace") } };
    defer for (&grace) |*f| f.deinit(gpa);
    var lin: [1]document_mod.Field = undefined;
    lin[0] = .{ .path = try gpa.dupe(u8, "name"), .item = .{ .text = try gpa.dupe(u8, "Lin") } };
    defer for (&lin) |*f| f.deinit(gpa);

    try eng.addNode("social", "1", &ada);
    try eng.addNode("social", "2", &grace);
    try eng.addNode("social", "3", &lin);
    try eng.addEdge("social", "1", "mentors", "2");
    try eng.addEdge("social", "1", "mentors", "3");
    try eng.addEdge("social", "2", "collaborates", "3");
}

test "navigate follows labeled edges and projects source and destination fields" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-graph";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestGraph(gpa, &eng);

    // Ada mentors Grace and Lin: navigate returns one row per matching edge,
    // with the source node's name and the destination under the alias.
    var request = try compile(gpa, "from social\n| navigate mentors as mentee\n| emit { name, mentee.name }\n| limit 5");
    defer request.deinit(gpa);
    var result = try execute(gpa, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.cells.len);
    try std.testing.expectEqualStrings("Ada", result.cells[0][0].?);
    try std.testing.expectEqualStrings("Grace", result.cells[0][1].?);
    try std.testing.expectEqualStrings("Ada", result.cells[1][0].?);
    try std.testing.expectEqualStrings("Lin", result.cells[1][1].?);

    // A node with no matching outgoing edge produces no row.
    var none = try compile(gpa, "from social\n| navigate collaborates as peer\n| where name = 'Ada'\n| emit { name, peer.name }");
    defer none.deinit(gpa);
    var none_result = try execute(gpa, &eng, &none);
    defer none_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), none_result.cells.len);

    // Without navigate, nodes read like documents.
    var plain = try compile(gpa, "from social\n| emit { name }\n| limit 2");
    defer plain.deinit(gpa);
    var plain_result = try execute(gpa, &eng, &plain);
    defer plain_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), plain_result.cells.len);
    try std.testing.expectEqualStrings("Ada", plain_result.cells[0][0].?);
}

test "graph source and equivalent IR produce the same navigate result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-graph-ir";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestGraph(gpa, &eng);

    const source = "from social\n| navigate mentors as mentee\n| emit { name, mentee.name }\n| limit 5";
    var request_a = try compile(gpa, source);
    defer request_a.deinit(gpa);
    var result_a = try execute(gpa, &eng, &request_a);
    defer result_a.deinit();

    const bytes = try ir.encode(gpa, &request_a);
    defer gpa.free(bytes);
    var request_b = try ir.decode(gpa, bytes);
    defer request_b.deinit(gpa);
    var result_b = try execute(gpa, &eng, &request_b);
    defer result_b.deinit();

    try std.testing.expectEqual(result_a.cells.len, result_b.cells.len);
    try std.testing.expectEqual(@as(usize, 2), result_a.cells.len);
    for (result_a.cells, 0..) |row, i| {
        try std.testing.expectEqualStrings(row[0].?, result_b.cells[i][0].?);
        try std.testing.expectEqualStrings(row[1].?, result_b.cells[i][1].?);
    }
}

test "navigate on a relation is rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-graph-reject";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
    defer columns[0].deinit(gpa);
    try eng.createTable("customer", &columns);

    var request = try compile(gpa, "from customer\n| navigate orders as order\n| emit { id }");
    defer request.deinit(gpa);
    try std.testing.expectError(error.UnsupportedNavigate, execute(gpa, &eng, &request));
}

// ── Cooperative cancellation probe (roadmap Phase 6) ──

/// Test probe that permits `remaining` bounded work units and then reports
/// cancellation, mirroring a Connection whose statement was marked by a
/// `CANCEL_REQUEST` while the scan was between two rows.
const CountingProbe = struct {
    remaining: usize,

    fn check(ctx: *anyopaque) error{Canceled}!void {
        const self: *CountingProbe = @ptrCast(@alignCast(ctx));
        if (self.remaining == 0) return error.Canceled;
        self.remaining -= 1;
    }
};

fn probeOpts(probe: *CountingProbe) ExecOptions {
    return .{ .cancel = .{ .ctx = probe, .check = CountingProbe.check } };
}

test "a cancellation probe stops a relation scan between bounded work units" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-cancel-relation";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
    defer columns[0].deinit(gpa);
    try eng.createTable("items", &columns);
    for (0..10) |i| try eng.insert("items", &.{.{ .int = @intCast(i) }});

    var request = try compile(gpa, "from items\n| emit { id }");
    defer request.deinit(gpa);

    // A probe that never fires leaves the scan untouched: identical result to
    // the plain execute path.
    var silent = CountingProbe{ .remaining = std.math.maxInt(usize) };
    var full = try executeOpts(gpa, &eng, &request, probeOpts(&silent));
    defer full.deinit();
    try std.testing.expectEqual(@as(usize, 10), full.cells.len);

    // A probe that fires after three rows stops the scan with error.Canceled;
    // the partially built result and the snapshot are released by the error
    // path, so the engine lock remains available to the caller.
    var firing = CountingProbe{ .remaining = 3 };
    try std.testing.expectError(error.Canceled, executeOpts(gpa, &eng, &request, probeOpts(&firing)));
}

test "a cancellation probe stops document and navigate scans" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-cancel-doc-graph";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestDocuments(gpa, &eng);
    try insertTestGraph(gpa, &eng);

    var doc_request = try compile(gpa, "from books\n| emit { title }");
    defer doc_request.deinit(gpa);
    var doc_probe = CountingProbe{ .remaining = 1 };
    try std.testing.expectError(error.Canceled, executeOpts(gpa, &eng, &doc_request, probeOpts(&doc_probe)));

    var nav_request = try compile(gpa, "from social\n| navigate mentors as mentee\n| emit { name, mentee.name }");
    defer nav_request.deinit(gpa);
    var nav_probe = CountingProbe{ .remaining = 1 };
    try std.testing.expectError(error.Canceled, executeOpts(gpa, &eng, &nav_request, probeOpts(&nav_probe)));

    // The evidence view observes the same cooperative boundary: the scan loop
    // checks the probe per committed observation record.
    _ = try eng.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "test-camera", "development", "payload");
    var ev_probe = CountingProbe{ .remaining = 0 };
    var ev_request = try compile(gpa, "from observation_evidence\n| emit { object_id }");
    defer ev_request.deinit(gpa);
    try std.testing.expectError(error.Canceled, executeOpts(gpa, &eng, &ev_request, probeOpts(&ev_probe)));
}

test "a cancellation probe applies to transaction-scoped reads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-cancel-tx";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
    defer columns[0].deinit(gpa);
    try eng.createTable("items", &columns);
    for (0..10) |i| try eng.insert("items", &.{.{ .int = @intCast(i) }});

    var request = try compile(gpa, "from items\n| emit { id }");
    defer request.deinit(gpa);
    var tx = eng.beginTransaction();
    defer tx.deinit();
    var probe = CountingProbe{ .remaining = 2 };
    try std.testing.expectError(error.Canceled, executeTxOpts(gpa, &eng, &request, &tx, probeOpts(&probe)));
}

