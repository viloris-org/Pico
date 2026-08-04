//! Streaming execution program (roadmap Phase 6).
//!
//! A `Program` is the execution instance of a bound Request: it owns the
//! bound projection, predicates, and scan state, and produces the result in
//! bounded batches instead of materializing every row up front. It follows
//! the `flow` module boundary in `docs/architecture-contract.yml` (owned
//! data: `execution_state`) and the execution-program domain term in
//! `CONTEXT.md`: one execution instance with a program counter (the cursor),
//! where each bounded batch is one work unit and each row is a cancellation
//! point.
//!
//! ## Ownership and locking
//!
//! `open`/`openTx` perform binding and snapshot acquisition and must be
//! called while the engine's statement-execution lock is held (the protocol
//! layer's `EngineGuard`). The cursor then iterates only owned snapshot
//! state: table rows are cloned by `selectAll`/`selectAllTx`, document and
//! node insertion order is cloned at open, navigate `(source, dest)` pairs
//! are pre-resolved under the lock, and the observation-evidence view is
//! cloned. `nextBatch` therefore never touches live engine state, so the
//! lock can be released after `open` and a slow result consumer blocks only
//! its own handler thread.
//!
//! ## Batching, cancellation, and accounting
//!
//! `nextBatch` fills a caller-owned `Batch` up to a `BatchLimit` (rows and
//! rendered bytes). The cancellation probe is checked before every row, so a
//! `CANCEL_REQUEST` mark stops the stream at the next row boundary; the
//! protocol layer additionally checks the mark between batches. The
//! `Metrics` count batches, rows, rendered bytes, cancellation checks, and
//! the largest batch, so queue-bound behavior is observable at the
//! execution-program boundary.
//!
//! The materialized `flow.exec` entry points drain the same program, so the
//! validated IR execution paths and the streaming path share one scan
//! implementation by construction.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const engine_mod = @import("../storage/engine.zig");
const table_mod = @import("../storage/table.zig");
const document_mod = @import("../storage/document.zig");
const kv_mod = @import("../storage/kv.zig");
const value = @import("../storage/value.zig");
const evidence = @import("../storage/evidence.zig");
const txn_mod = @import("../txn/transaction.zig");

pub const ProgramError = error{
    SemanticNameNotFound,
    FieldNotFound,
    TypeMismatch,
    NonComparableColumn,
    ModelRevisionMismatch,
    UnsupportedNavigate,
    InvalidOperation,
    Canceled,
} || Allocator.Error;

/// Cooperative cancellation probe (roadmap Phase 6). The caller — a RunaDB
/// Connection — owns the state and the statement generation that a
/// `CANCEL_REQUEST` marks; the flow module only calls `check` between bounded
/// work units during scan execution and never stores the probe past the call.
/// A null probe disables cancellation, preserving the engine-level and MCP
/// call paths unchanged.
pub const CancelProbe = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque) error{Canceled}!void,
};

/// Per-execution options. The default options carry no cancellation probe.
pub const ExecOptions = struct {
    cancel: ?CancelProbe = null,
};

fn checkCancel(opts: ExecOptions) ProgramError!void {
    if (opts.cancel) |probe| try probe.check(probe.ctx);
}

// ── Rendering and binding helpers (shared by every cursor) ──

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

/// Render one value into an owned cell slice (null renders as null).
pub fn valueToText(gpa: Allocator, owned: *std.ArrayList([]u8), item: value.Value) !?[]const u8 {
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

fn ownedFormat(gpa: Allocator, owned: *std.ArrayList([]u8), comptime format: []const u8, args: anytype) ![]const u8 {
    const text = try std.fmt.allocPrint(gpa, format, args);
    errdefer gpa.free(text);
    try owned.append(gpa, text);
    return text;
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

/// Bound predicates for a document collection. Predicate `col_index` is the
/// predicate's position; the cursor fills a per-document value array at those
/// positions. `owned` holds the allocated `in`-list value arrays.
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

fn evidenceFieldIndex(name: []const u8) ?usize {
    for (evidence_fields, 0..) |field, index| {
        if (std.mem.eql(u8, name, field.name)) return index;
    }
    return null;
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

/// Render one evidence field into an owned cell. All text is copied into the
/// batch's `owned_text`, so a batch is fully self-owned even though the
/// record strings live in the engine's observation store.
fn renderEvidenceField(gpa: Allocator, owned_text: *std.ArrayList([]u8), record: *const evidence.Record, field_index: usize) ProgramError!?[]const u8 {
    return switch (field_index) {
        0 => try ownedFormat(gpa, owned_text, "{d}", .{record.evidence_id}),
        1 => try valueToText(gpa, owned_text, .{ .text = record.object_id }),
        2 => @tagName(record.modality),
        3 => try valueToText(gpa, owned_text, .{ .text = record.media_type }),
        4 => try valueToText(gpa, owned_text, .{ .text = record.observed_at }),
        5 => try valueToText(gpa, owned_text, .{ .text = record.origin }),
        6 => try valueToText(gpa, owned_text, .{ .text = record.owner }),
        7 => try ownedFormat(gpa, owned_text, "{d}", .{record.payload_length}),
        8 => blk: {
            const hex = std.fmt.bytesToHex(record.payload_digest, .lower);
            const text = try gpa.dupe(u8, &hex);
            try owned_text.append(gpa, text);
            break :blk text;
        },
        else => unreachable,
    };
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

/// Resolve an emit path against a navigate row: `alias.<path>` reads the
/// destination node, any other path reads the source node.
fn graphPathValue(alias: []const u8, source: *const document_mod.Document, dest: *const document_mod.Document, path: []const u8) ?value.Value {
    if (std.mem.startsWith(u8, path, alias) and path.len > alias.len and path[alias.len] == '.') {
        return dest.pathValue(path[alias.len + 1 ..]);
    }
    return source.pathValue(path);
}

// ── Scan cursors ──

/// Relation table scan over the owned snapshot. `rows` is the fully cloned
/// `SelectResult`, so iteration after the statement lock is released is safe.
const TableCursor = struct {
    gpa: Allocator,
    projection: []usize,
    bound: BoundWhere,
    rows: engine_mod.Engine.SelectResult,
    index: usize = 0,

    fn deinit(self: *TableCursor) void {
        self.gpa.free(self.projection);
        self.bound.deinit();
        self.rows.deinit();
    }

    fn nextRow(self: *TableCursor, gpa: Allocator, owned_text: *std.ArrayList([]u8)) ProgramError!?[]?[]const u8 {
        // Advance the cursor before returning so a produced row is never
        // produced again on the next call.
        while (self.index < self.rows.rows.len) {
            const row_index = self.index;
            self.index += 1;
            const row = &self.rows.rows[row_index];
            if (!table_mod.valuesMatch(row.values, self.bound.preds)) continue;
            const output = try gpa.alloc(?[]const u8, self.projection.len);
            errdefer gpa.free(output);
            for (self.projection, 0..) |column, output_index| {
                output[output_index] = try valueToText(gpa, owned_text, row.values[column]);
            }
            return output;
        }
        return null;
    }
};

/// Document collection (and plain graph node) scan. `order` is a clone of the
/// collection's insertion order taken under the statement lock; documents are
/// immutable after insert, so `pathValue` reads stay safe after the lock is
/// released.
const DocumentCursor = struct {
    gpa: Allocator,
    bound: BoundDocumentWhere,
    order: []*document_mod.Document,
    /// Predicate column paths, borrowed from the Request (which outlives the
    /// program). Predicate `col_index` is the predicate's position.
    where: []const ast.Predicate,
    index: usize = 0,

    fn deinit(self: *DocumentCursor) void {
        self.bound.deinit();
        self.gpa.free(self.order);
    }

    fn nextRow(self: *DocumentCursor, gpa: Allocator, owned_text: *std.ArrayList([]u8), projection: [][]const u8, pred_values: []value.Value) ProgramError!?[]?[]const u8 {
        while (self.index < self.order.len) {
            const doc_index = self.index;
            self.index += 1;
            const doc = self.order[doc_index];
            for (self.bound.preds, 0..) |_, pred_index| {
                pred_values[pred_index] = doc.pathValue(self.where[pred_index].column) orelse .null;
            }
            if (!table_mod.valuesMatch(pred_values, self.bound.preds)) continue;
            const output = try gpa.alloc(?[]const u8, projection.len);
            errdefer gpa.free(output);
            for (projection, 0..) |path, index| {
                output[index] = try valueToText(gpa, owned_text, doc.pathValue(path) orelse .null);
            }
            return output;
        }
        return null;
    }
};

/// Graph scan. Without `navigate` it reads nodes exactly like documents. With
/// `navigate`, `pairs` holds every surviving `(source, dest)` pair pre-resolved
/// under the statement lock, so the cursor never touches live graph state
/// (edges array, node map) after the lock is released.
const GraphCursor = struct {
    gpa: Allocator,
    bound: BoundDocumentWhere,
    order: []*document_mod.Document,
    pairs: []NavPair,
    nav: ?struct { alias: []const u8, edge: []const u8 } = null,
    /// Predicate column paths, borrowed from the Request (which outlives the
    /// program).
    where: []const ast.Predicate,
    index: usize = 0,

    const NavPair = struct {
        source: *document_mod.Document,
        dest: *document_mod.Document,
    };

    fn deinit(self: *GraphCursor) void {
        self.bound.deinit();
        self.gpa.free(self.order);
        self.gpa.free(self.pairs);
    }

    fn nextRow(self: *GraphCursor, gpa: Allocator, owned_text: *std.ArrayList([]u8), projection: [][]const u8, pred_values: []value.Value) ProgramError!?[]?[]const u8 {
        if (self.nav) |nav| {
            while (self.index < self.pairs.len) {
                const pair_index = self.index;
                self.index += 1;
                const pair = self.pairs[pair_index];
                for (self.bound.preds, 0..) |_, pred_index| {
                    pred_values[pred_index] = pair.source.pathValue(self.where[pred_index].column) orelse .null;
                }
                if (!table_mod.valuesMatch(pred_values, self.bound.preds)) continue;
                const output = try gpa.alloc(?[]const u8, projection.len);
                errdefer gpa.free(output);
                for (projection, 0..) |path, index| {
                    output[index] = try valueToText(gpa, owned_text, graphPathValue(nav.alias, pair.source, pair.dest, path) orelse .null);
                }
                return output;
            }
            return null;
        }
        // Plain node scan: identical to a document scan over the node order.
        while (self.index < self.order.len) {
            const node_index = self.index;
            self.index += 1;
            const node = self.order[node_index];
            for (self.bound.preds, 0..) |_, pred_index| {
                pred_values[pred_index] = node.pathValue(self.where[pred_index].column) orelse .null;
            }
            if (!table_mod.valuesMatch(pred_values, self.bound.preds)) continue;
            const output = try gpa.alloc(?[]const u8, projection.len);
            errdefer gpa.free(output);
            for (projection, 0..) |path, index| {
                output[index] = try valueToText(gpa, owned_text, node.pathValue(path) orelse .null);
            }
            return output;
        }
        return null;
    }
};

/// KV collection scan. Each entry reads as a two-field row: `key` (text) and
/// `value` (scalar). `order` is a clone of the map's insertion order taken
/// under the statement lock; entries are immutable after their last upsert,
/// so reads stay safe after the lock is released. An emit path other than
/// `key`/`value` reads as null, exactly like an absent document field.
const KvCursor = struct {
    gpa: Allocator,
    bound: BoundDocumentWhere,
    order: []*kv_mod.Entry,
    /// Predicate column paths, borrowed from the Request (which outlives the
    /// program).
    where: []const ast.Predicate,
    index: usize = 0,

    fn deinit(self: *KvCursor) void {
        self.bound.deinit();
        self.gpa.free(self.order);
    }

    /// Resolve an emit/where path against a KV entry: `key` is the text key,
    /// `value` is the scalar value, and any other path reads as null.
    fn pathValue(entry: *const kv_mod.Entry, path: []const u8) ?value.Value {
        if (std.mem.eql(u8, path, "key")) return .{ .text = entry.key };
        if (std.mem.eql(u8, path, "value")) return entry.item;
        return null;
    }

    fn nextRow(self: *KvCursor, gpa: Allocator, owned_text: *std.ArrayList([]u8), projection: [][]const u8, pred_values: []value.Value) ProgramError!?[]?[]const u8 {
        while (self.index < self.order.len) {
            const entry_index = self.index;
            self.index += 1;
            const entry = self.order[entry_index];
            for (self.bound.preds, 0..) |_, pred_index| {
                pred_values[pred_index] = pathValue(entry, self.where[pred_index].column) orelse .null;
            }
            if (!table_mod.valuesMatch(pred_values, self.bound.preds)) continue;
            const output = try gpa.alloc(?[]const u8, projection.len);
            errdefer gpa.free(output);
            for (projection, 0..) |path, index| {
                output[index] = try valueToText(gpa, owned_text, pathValue(entry, path) orelse .null);
            }
            return output;
        }
        return null;
    }
};

/// Observation evidence scan over a cloned view of the observation store. The
/// record structs are copied at open; their strings are stable engine
/// allocations, so the clone stays valid after the statement lock is released.
const EvidenceCursor = struct {
    gpa: Allocator,
    projection: []usize,
    bound: BoundWhere,
    records: []evidence.Record,
    index: usize = 0,

    fn deinit(self: *EvidenceCursor) void {
        self.gpa.free(self.projection);
        self.bound.deinit();
        self.gpa.free(self.records);
    }

    fn nextRow(self: *EvidenceCursor, gpa: Allocator, owned_text: *std.ArrayList([]u8)) ProgramError!?[]?[]const u8 {
        var digest_hex: [2 * evidence.DIGEST_LENGTH]u8 = undefined;
        var values_buf: [evidence_fields.len]value.Value = undefined;
        while (self.index < self.records.len) {
            const record_index = self.index;
            self.index += 1;
            const record = &self.records[record_index];
            for (0..values_buf.len) |field_index| values_buf[field_index] = evidenceValue(record, field_index, &digest_hex);
            if (!table_mod.valuesMatch(&values_buf, self.bound.preds)) continue;
            const output = try gpa.alloc(?[]const u8, self.projection.len);
            errdefer gpa.free(output);
            for (self.projection, 0..) |field_index, output_index| {
                output[output_index] = try renderEvidenceField(gpa, owned_text, record, field_index);
            }
            return output;
        }
        return null;
    }
};

// ── Batch ──

/// One bounded output batch. Rows and their cell text are fully owned by the
/// batch and freed by `deinit` (or reset by `reset` for the next batch), so
/// at any time only the current batch's rendered text exists: streaming
/// production is memory-bounded at the batch boundary.
pub const Batch = struct {
    gpa: Allocator,
    rows: std.ArrayList([]?[]const u8) = .empty,
    owned_text: std.ArrayList([]u8) = .empty,
    rendered_bytes: u64 = 0,
    /// True when the scan or the Request's limit is exhausted; the caller
    /// must not call `nextBatch` again after a done batch.
    done: bool = false,

    pub fn deinit(self: *Batch) void {
        for (self.rows.items) |row| self.gpa.free(row);
        self.rows.deinit(self.gpa);
        for (self.owned_text.items) |text| self.gpa.free(text);
        self.owned_text.deinit(self.gpa);
        self.* = undefined;
    }

    /// Free the previous batch's rows and text so the batch can be refilled.
    pub fn reset(self: *Batch) void {
        for (self.rows.items) |row| self.gpa.free(row);
        self.rows.clearRetainingCapacity();
        for (self.owned_text.items) |text| self.gpa.free(text);
        self.owned_text.clearRetainingCapacity();
        self.rendered_bytes = 0;
        self.done = false;
    }

    /// Transfer the batch's rows and text to the caller without freeing (the
    /// materialized drain moves each released batch into a `Result`). The
    /// batch is left empty and reusable; `deinit` stays safe on it.
    pub fn release(self: *Batch) BatchParts {
        const parts = BatchParts{ .rows = self.rows, .owned_text = self.owned_text };
        self.rows = .empty;
        self.owned_text = .empty;
        self.rendered_bytes = 0;
        return parts;
    }
};

/// Owned rows and cell text handed out by `Batch.release`.
pub const BatchParts = struct {
    rows: std.ArrayList([]?[]const u8),
    owned_text: std.ArrayList([]u8),

    pub fn deinit(self: *BatchParts, gpa: Allocator) void {
        for (self.rows.items) |row| gpa.free(row);
        self.rows.deinit(gpa);
        for (self.owned_text.items) |text| gpa.free(text);
        self.owned_text.deinit(gpa);
    }
};

pub const BatchLimit = struct {
    max_rows: usize = 64,
    max_bytes: u64 = 1024 * 1024,
};

/// Resource accounting at the execution-program boundary.
pub const Metrics = struct {
    batches: u64 = 0,
    rows_emitted: u64 = 0,
    rendered_bytes: u64 = 0,
    cancel_checks: u64 = 0,
    max_batch_rows: usize = 0,
    max_batch_bytes: u64 = 0,
};

// ── Program ──

pub const Program = struct {
    gpa: Allocator,
    opts: ExecOptions,
    columns: [][]const u8,
    column_text: std.ArrayList([]u8),
    max_rows: usize,
    emitted: usize = 0,
    cursor: Cursor,
    /// Scratch values for document/graph predicate evaluation, sized
    /// `request.where.len`.
    pred_scratch: ?[]value.Value = null,
    metrics: Metrics = .{},
    done: bool = false,

    pub const Cursor = union(enum) {
        table: TableCursor,
        document: DocumentCursor,
        graph: GraphCursor,
        evidence: EvidenceCursor,
        kv: KvCursor,
    };

    pub fn deinit(self: *Program) void {
        if (self.columns.len != 0) self.gpa.free(self.columns);
        for (self.column_text.items) |text| self.gpa.free(text);
        self.column_text.deinit(self.gpa);
        switch (self.cursor) {
            .table => |*cursor| cursor.deinit(),
            .document => |*cursor| cursor.deinit(),
            .graph => |*cursor| cursor.deinit(),
            .evidence => |*cursor| cursor.deinit(),
            .kv => |*cursor| cursor.deinit(),
        }
        if (self.pred_scratch) |scratch| self.gpa.free(scratch);
        self.* = undefined;
    }

    /// Transfer ownership of the column metadata (names and array) to the
    /// caller. The materialized drain uses this so a `Result` owns its columns
    /// after the program is deinitialized.
    pub fn takeColumns(self: *Program) struct { columns: [][]const u8, column_text: std.ArrayList([]u8) } {
        const columns = self.columns;
        const column_text = self.column_text;
        self.columns = &[_][]const u8{};
        self.column_text = .empty;
        return .{ .columns = columns, .column_text = column_text };
    }

    /// Produce the next bounded batch. `limit.max_rows` must be nonzero. The
    /// cancellation probe is checked before every row, so a marked statement
    /// stops at the next row boundary with `error.Canceled`.
    pub fn nextBatch(self: *Program, batch: *Batch, limit: BatchLimit) ProgramError!void {
        std.debug.assert(limit.max_rows > 0);
        batch.reset();
        self.metrics.batches += 1;
        var produced: usize = 0;
        while (produced < limit.max_rows and batch.rendered_bytes < limit.max_bytes) {
            if (self.emitted >= self.max_rows) {
                self.done = true;
                break;
            }
            // Accounting is incremental so a batch that fails mid-way (a
            // cancellation at the next row boundary) still reports the rows
            // and bytes it produced.
            self.metrics.cancel_checks += 1;
            try checkCancel(self.opts);
            const row = try self.nextRow(batch) orelse {
                self.done = true;
                break;
            };
            var row_bytes: u64 = 0;
            for (row) |cell| {
                if (cell) |text| row_bytes += text.len;
            }
            batch.rendered_bytes += row_bytes;
            self.metrics.rendered_bytes += row_bytes;
            try batch.rows.append(self.gpa, row);
            self.emitted += 1;
            produced += 1;
            self.metrics.rows_emitted += 1;
        }
        batch.done = self.done;
        if (produced > self.metrics.max_batch_rows) self.metrics.max_batch_rows = produced;
        if (batch.rendered_bytes > self.metrics.max_batch_bytes) self.metrics.max_batch_bytes = batch.rendered_bytes;
    }

    fn nextRow(self: *Program, batch: *Batch) ProgramError!?[]?[]const u8 {
        return switch (self.cursor) {
            .table => |*cursor| cursor.nextRow(self.gpa, &batch.owned_text),
            .document => |*cursor| cursor.nextRow(self.gpa, &batch.owned_text, self.columns, self.pred_scratch.?),
            .graph => |*cursor| cursor.nextRow(self.gpa, &batch.owned_text, self.columns, self.pred_scratch.?),
            .evidence => |*cursor| cursor.nextRow(self.gpa, &batch.owned_text),
            .kv => |*cursor| cursor.nextRow(self.gpa, &batch.owned_text, self.columns, self.pred_scratch.?),
        };
    }
};

// ── Program opening ──

/// Open a streaming execution program for a read-only Request. Must be called
/// with the engine's statement-execution lock held (the protocol layer's
/// `EngineGuard`): binding and snapshot acquisition read live engine state.
pub fn open(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, opts: ExecOptions) ProgramError!Program {
    return openAny(gpa, eng, request, null, opts);
}

/// Open a streaming execution program through an explicit transaction (Read
/// Committed with read-your-writes). Must be called with the statement lock
/// held.
pub fn openTx(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, tx: *txn_mod.Transaction, opts: ExecOptions) ProgramError!Program {
    return openAny(gpa, eng, request, tx, opts);
}

fn openAny(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, tx: ?*txn_mod.Transaction, opts: ExecOptions) ProgramError!Program {
    if (request.model_revision != ir.DEVELOPMENT_MODEL_REVISION) return error.ModelRevisionMismatch;
    if (request.operation != .emit) return error.InvalidOperation;
    if (std.mem.eql(u8, request.relation, "observation_evidence")) return openEvidence(gpa, eng, request, opts);
    // Document and graph collections have no private write set in this slice;
    // they are read from committed state exactly as outside a transaction.
    if (eng.getDocumentCollection(request.relation)) |_| {
        if (request.navigate != null) return error.UnsupportedNavigate;
        return openDocument(gpa, eng, request, opts);
    }
    if (eng.getGraph(request.relation) != null) return openGraph(gpa, eng, request, opts);
    if (eng.getKvMap(request.relation) != null) return openKv(gpa, eng, request, opts);
    return openTable(gpa, eng, request, tx, opts);
}

fn openTable(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, tx: ?*txn_mod.Transaction, opts: ExecOptions) ProgramError!Program {
    const table = eng.getTable(request.relation) orelse return error.SemanticNameNotFound;
    if (request.navigate != null) return error.UnsupportedNavigate;
    const projection = try bindProjection(gpa, table, request.fields);
    errdefer gpa.free(projection);
    var bound = try bindTableWhere(gpa, table, request.where);
    errdefer bound.deinit();

    // Read Committed: the statement takes a fresh snapshot watermark at its
    // start and interprets only complete commits at or before it. The engine's
    // snapshot-aware scan registers the watermark for the read's duration and
    // returns only versions visible at it; the cursor keeps reading them even
    // as later commits land (reads do not wait for writes).
    const snapshot_seq = eng.publishedSeq();
    var rows = (if (tx) |t|
        eng.selectAllTx(t, request.relation, snapshot_seq)
    else
        eng.selectAll(request.relation, snapshot_seq)) catch |err| switch (err) {
        error.TableNotFound => return error.SemanticNameNotFound,
        error.SnapshotLimitExceeded => return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer rows.deinit();

    var column_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (column_text.items) |text| gpa.free(text);
        column_text.deinit(gpa);
    }
    const columns = try gpa.alloc([]const u8, projection.len);
    errdefer gpa.free(columns);
    for (projection, 0..) |index, output_index| {
        columns[output_index] = try ownColumn(gpa, &column_text, table.columns[index].name);
    }
    return .{
        .gpa = gpa,
        .opts = opts,
        .columns = columns,
        .column_text = column_text,
        .max_rows = if (request.limit) |limit| @intCast(limit) else std.math.maxInt(usize),
        .cursor = .{ .table = .{ .gpa = gpa, .projection = projection, .bound = bound, .rows = rows } },
    };
}

fn openKv(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, opts: ExecOptions) ProgramError!Program {
    const map = eng.getKvMap(request.relation) orelse return error.SemanticNameNotFound;
    if (request.navigate != null) return error.UnsupportedNavigate;
    var bound = try bindDocumentWhere(gpa, request.where);
    errdefer bound.deinit();
    // Clone the insertion order under the lock: an upsert appends or replaces
    // entries, but a read never follows a replaced entry's old value after the
    // lock is released because each entry is updated in place under the lock.
    const order = try gpa.dupe(*kv_mod.Entry, map.order.items);
    errdefer gpa.free(order);
    const pred_scratch = try gpa.alloc(value.Value, request.where.len);
    errdefer gpa.free(pred_scratch);

    var column_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (column_text.items) |text| gpa.free(text);
        column_text.deinit(gpa);
    }
    const columns = try gpa.alloc([]const u8, request.fields.len);
    errdefer gpa.free(columns);
    for (request.fields, 0..) |path, index| {
        columns[index] = try ownColumn(gpa, &column_text, path);
    }
    return .{
        .gpa = gpa,
        .opts = opts,
        .columns = columns,
        .column_text = column_text,
        .max_rows = if (request.limit) |limit| @intCast(limit) else std.math.maxInt(usize),
        .pred_scratch = pred_scratch,
        .cursor = .{ .kv = .{ .gpa = gpa, .bound = bound, .order = order, .where = request.where } },
    };
}

fn openDocument(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, opts: ExecOptions) ProgramError!Program {
    const collection = eng.getDocumentCollection(request.relation) orelse return error.SemanticNameNotFound;
    var bound = try bindDocumentWhere(gpa, request.where);
    errdefer bound.deinit();
    // Clone the insertion order under the lock: a concurrent insert reallocates
    // the collection's order array, but the pointed-to documents are immutable.
    const order = try gpa.dupe(*document_mod.Document, collection.order.items);
    errdefer gpa.free(order);
    const pred_scratch = try gpa.alloc(value.Value, request.where.len);
    errdefer gpa.free(pred_scratch);

    var column_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (column_text.items) |text| gpa.free(text);
        column_text.deinit(gpa);
    }
    const columns = try gpa.alloc([]const u8, request.fields.len);
    errdefer gpa.free(columns);
    for (request.fields, 0..) |path, index| {
        columns[index] = try ownColumn(gpa, &column_text, path);
    }
    return .{
        .gpa = gpa,
        .opts = opts,
        .columns = columns,
        .column_text = column_text,
        .max_rows = if (request.limit) |limit| @intCast(limit) else std.math.maxInt(usize),
        .pred_scratch = pred_scratch,
        .cursor = .{ .document = .{ .gpa = gpa, .bound = bound, .order = order, .where = request.where } },
    };
}

fn openGraph(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, opts: ExecOptions) ProgramError!Program {
    const graph = eng.getGraph(request.relation) orelse return error.SemanticNameNotFound;
    const navigate = request.navigate;
    var bound = try bindDocumentWhere(gpa, request.where);
    errdefer bound.deinit();
    const order = try gpa.dupe(*document_mod.Document, graph.nodes.order.items);
    errdefer gpa.free(order);
    const pred_scratch = try gpa.alloc(value.Value, request.where.len);
    errdefer gpa.free(pred_scratch);

    var pairs: std.ArrayList(GraphCursor.NavPair) = .empty;
    errdefer pairs.deinit(gpa);
    if (navigate) |nav| {
        // Pre-resolve (source, dest) pairs under the statement lock so the
        // cursor never touches live edge/node state after the lock is released.
        for (graph.nodes.order.items) |source| {
            for (graph.edges.items) |*edge_item| {
                if (!std.mem.eql(u8, edge_item.from, source.id) or !std.mem.eql(u8, edge_item.label, nav.edge)) continue;
                const dest = graph.nodes.by_id.get(edge_item.to) orelse continue;
                try pairs.append(gpa, .{ .source = source, .dest = dest });
            }
        }
    }
    const pair_slice = try pairs.toOwnedSlice(gpa);
    errdefer gpa.free(pair_slice);

    var column_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (column_text.items) |text| gpa.free(text);
        column_text.deinit(gpa);
    }
    const columns = try gpa.alloc([]const u8, request.fields.len);
    errdefer gpa.free(columns);
    for (request.fields, 0..) |path, index| {
        columns[index] = try ownColumn(gpa, &column_text, path);
    }
    return .{
        .gpa = gpa,
        .opts = opts,
        .columns = columns,
        .column_text = column_text,
        .max_rows = if (request.limit) |limit| @intCast(limit) else std.math.maxInt(usize),
        .pred_scratch = pred_scratch,
        .cursor = .{ .graph = .{
            .gpa = gpa,
            .bound = bound,
            .order = order,
            .pairs = pair_slice,
            .nav = if (navigate) |nav| .{ .alias = nav.alias, .edge = nav.edge } else null,
            .where = request.where,
        } },
    };
}

fn openEvidence(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, opts: ExecOptions) ProgramError!Program {
    const projection = try gpa.alloc(usize, request.fields.len);
    errdefer gpa.free(projection);
    for (request.fields, 0..) |field, output_index| {
        projection[output_index] = evidenceFieldIndex(field) orelse return error.FieldNotFound;
    }
    var bound = try bindEvidenceWhere(gpa, request.where);
    errdefer bound.deinit();
    // Clone the observation view under the lock: appends reallocate the store's
    // record array, but each record's strings are stable allocations.
    const records = try gpa.dupe(evidence.Record, eng.observationsView());
    errdefer gpa.free(records);

    var column_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (column_text.items) |text| gpa.free(text);
        column_text.deinit(gpa);
    }
    const columns = try gpa.alloc([]const u8, request.fields.len);
    errdefer gpa.free(columns);
    for (projection, 0..) |field_index, index| {
        columns[index] = try ownColumn(gpa, &column_text, evidence_fields[field_index].name);
    }
    return .{
        .gpa = gpa,
        .opts = opts,
        .columns = columns,
        .column_text = column_text,
        .max_rows = if (request.limit) |limit| @intCast(limit) else std.math.maxInt(usize),
        .cursor = .{ .evidence = .{ .gpa = gpa, .projection = projection, .bound = bound, .records = records } },
    };
}

// ── Tests ──

fn testEngine(gpa: Allocator, io: Io, dir: []const u8) !engine_mod.Engine {
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    errdefer Io.Dir.cwd().deleteTree(io, dir) catch {};
    return engine_mod.Engine.open(gpa, io, dir, false);
}

/// Owned rows and cell text drained from a program (the tests' counterpart
/// of the materialized drain in `flow.exec`).
const DrainedRows = struct {
    rows: std.ArrayList([]?[]const u8) = .empty,
    owned_text: std.ArrayList([]u8) = .empty,

    fn deinit(self: *DrainedRows, gpa: Allocator) void {
        for (self.rows.items) |row| gpa.free(row);
        self.rows.deinit(gpa);
        for (self.owned_text.items) |text| gpa.free(text);
        self.owned_text.deinit(gpa);
    }
};

/// Concatenate every batch a program produces into one owned result: rows and
/// their cell text are moved out of each batch (like the materialized drain),
/// so the caller owns everything and the batch stays reusable.
fn drainToRows(gpa: Allocator, prog: *Program, batch: *Batch, max_rows: usize, max_bytes: u64) !DrainedRows {
    var drained: DrainedRows = .{};
    errdefer drained.deinit(gpa);
    while (true) {
        try prog.nextBatch(batch, .{ .max_rows = max_rows, .max_bytes = max_bytes });
        var parts = batch.release();
        errdefer parts.deinit(gpa);
        try drained.rows.ensureUnusedCapacity(gpa, parts.rows.items.len);
        try drained.owned_text.ensureUnusedCapacity(gpa, parts.owned_text.items.len);
        for (parts.rows.items) |row| drained.rows.appendAssumeCapacity(row);
        for (parts.owned_text.items) |text| drained.owned_text.appendAssumeCapacity(text);
        var moved_rows = parts.rows;
        var moved_text = parts.owned_text;
        moved_rows.deinit(gpa);
        moved_text.deinit(gpa);
        if (batch.done) break;
    }
    return drained;
}

/// Bind a Flow source like `flow.exec.compile`: parse, bind, and free the
/// parsed source so nothing leaks.
fn bindSource(gpa: Allocator, source: []const u8) !ir.Request {
    var parsed = try ast.parse(gpa, source);
    defer parsed.deinit(gpa);
    return ir.bind(gpa, parsed);
}

test "bounded batches partition a scan and concatenate to the full result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var eng = try testEngine(gpa, io, "zig-cache/runadb-program-batches");
    defer eng.deinit();
    var cols = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int }};
    defer cols[0].deinit(gpa);
    try eng.createTable("items", &cols);
    for (0..10) |i| try eng.insert("items", &.{.{ .int = @intCast(i) }});

    var request = try bindSource(gpa, "from items\n| emit { id }");
    defer request.deinit(gpa);

    var prog = try open(gpa, &eng, &request, .{});
    defer prog.deinit();
    var batch: Batch = .{ .gpa = gpa };
    defer batch.deinit();

    // Three-row batches: 3, 3, 3, 1. Only the last batch reports done.
    try prog.nextBatch(&batch, .{ .max_rows = 3, .max_bytes = std.math.maxInt(u64) });
    try std.testing.expectEqual(@as(usize, 3), batch.rows.items.len);
    try std.testing.expect(!batch.done);
    try prog.nextBatch(&batch, .{ .max_rows = 3, .max_bytes = std.math.maxInt(u64) });
    try std.testing.expectEqual(@as(usize, 3), batch.rows.items.len);
    try std.testing.expect(!batch.done);
    try prog.nextBatch(&batch, .{ .max_rows = 3, .max_bytes = std.math.maxInt(u64) });
    try std.testing.expectEqual(@as(usize, 3), batch.rows.items.len);
    try std.testing.expect(!batch.done);
    try prog.nextBatch(&batch, .{ .max_rows = 3, .max_bytes = std.math.maxInt(u64) });
    try std.testing.expectEqual(@as(usize, 1), batch.rows.items.len);
    try std.testing.expect(batch.done);

    // Resource accounting at the boundary: four batches, ten rows, monotone
    // byte count, and the largest batch is exactly the 3-row cap.
    const metrics = prog.metrics;
    try std.testing.expectEqual(@as(u64, 4), metrics.batches);
    try std.testing.expectEqual(@as(u64, 10), metrics.rows_emitted);
    try std.testing.expect(metrics.rendered_bytes >= 10);
    try std.testing.expectEqual(@as(usize, 3), metrics.max_batch_rows);
}

test "byte limit bounds a batch and a single oversized row is delivered alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var eng = try testEngine(gpa, io, "zig-cache/runadb-program-bytes");
    defer eng.deinit();
    try eng.createDocument("docs");
    var text: value.Value = .{ .text = try gpa.dupe(u8, "abcdefghij") };
    defer text.deinit(gpa);
    const fields = [_]document_mod.Field{.{ .path = @constCast("payload"), .item = text }};
    for (0..6) |i| {
        var id_buf: [8]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "d{d}", .{i}) catch unreachable;
        try eng.insertDocument("docs", id, &fields);
    }

    var request = try bindSource(gpa, "from docs\n| emit { payload }");
    defer request.deinit(gpa);
    var prog = try open(gpa, &eng, &request, .{});
    defer prog.deinit();
    var batch: Batch = .{ .gpa = gpa };
    defer batch.deinit();

    // max_bytes = 25 with 10-byte payloads: rows are produced while the
    // rendered byte count stays below the cap, so three rows (30 bytes)
    // fit the batch and the fourth is deferred.
    try prog.nextBatch(&batch, .{ .max_rows = 100, .max_bytes = 25 });
    try std.testing.expectEqual(@as(usize, 3), batch.rows.items.len);
    try std.testing.expect(batch.rendered_bytes >= 30);
    try std.testing.expect(!batch.done);

    // A 5-byte cap cannot fit even one 10-byte row, but an oversized row is
    // never dropped: it is delivered alone.
    try prog.nextBatch(&batch, .{ .max_rows = 100, .max_bytes = 5 });
    try std.testing.expectEqual(@as(usize, 1), batch.rows.items.len);
    try std.testing.expect(batch.rendered_bytes >= 10);
    try std.testing.expect(!batch.done);
}

test "the request limit is respected across batches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var eng = try testEngine(gpa, io, "zig-cache/runadb-program-limit");
    defer eng.deinit();
    try eng.createDocument("docs");
    var text: value.Value = .{ .text = try gpa.dupe(u8, "x") };
    defer text.deinit(gpa);
    const fields = [_]document_mod.Field{.{ .path = @constCast("id"), .item = text }};
    for (0..10) |i| {
        var id_buf: [8]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "d{d}", .{i}) catch unreachable;
        try eng.insertDocument("docs", id, &fields);
    }

    var request = try bindSource(gpa, "from docs\n| emit { id }\n| limit 5");
    defer request.deinit(gpa);
    var prog = try open(gpa, &eng, &request, .{});
    defer prog.deinit();
    var batch: Batch = .{ .gpa = gpa };
    defer batch.deinit();

    var drained = try drainToRows(gpa, &prog, &batch, 2, std.math.maxInt(u64));
    defer drained.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 5), drained.rows.items.len);
    try std.testing.expectEqual(@as(u64, 5), prog.metrics.rows_emitted);
}

/// Probe that permits `remaining` bounded work units and then reports
/// cancellation (mirrors a Connection whose statement was marked while the
/// scan was between rows).
const CountingProbe = struct {
    remaining: usize,

    fn check(ctx: *anyopaque) error{Canceled}!void {
        const self: *CountingProbe = @ptrCast(@alignCast(ctx));
        if (self.remaining == 0) return error.Canceled;
        self.remaining -= 1;
    }
};

test "cancellation stops a stream at the next row boundary across batches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var eng = try testEngine(gpa, io, "zig-cache/runadb-program-cancel");
    defer eng.deinit();
    var cols = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int }};
    defer cols[0].deinit(gpa);
    try eng.createTable("items", &cols);
    for (0..10) |i| try eng.insert("items", &.{.{ .int = @intCast(i) }});

    var request = try bindSource(gpa, "from items\n| emit { id }");
    defer request.deinit(gpa);

    // Two batches of three rows, then the third batch produces one more row
    // before the mark stops the stream with error.Canceled.
    var probe = CountingProbe{ .remaining = 7 };
    var prog = try open(gpa, &eng, &request, .{ .cancel = .{ .ctx = &probe, .check = CountingProbe.check } });
    defer prog.deinit();
    var batch: Batch = .{ .gpa = gpa };
    defer batch.deinit();

    try prog.nextBatch(&batch, .{ .max_rows = 3, .max_bytes = std.math.maxInt(u64) });
    try std.testing.expectEqual(@as(usize, 3), batch.rows.items.len);
    try prog.nextBatch(&batch, .{ .max_rows = 3, .max_bytes = std.math.maxInt(u64) });
    try std.testing.expectEqual(@as(usize, 3), batch.rows.items.len);
    try std.testing.expectError(error.Canceled, prog.nextBatch(&batch, .{ .max_rows = 3, .max_bytes = std.math.maxInt(u64) }));
    // The program produced exactly seven rows before the mark was observed
    // (the probe permits seven bounded work units; the eighth check fails).
    try std.testing.expectEqual(@as(u64, 7), prog.metrics.rows_emitted);
    // Every row check counted: one per produced row plus the failing check.
    try std.testing.expectEqual(@as(u64, 8), prog.metrics.cancel_checks);
}

test "the streamed concatenation matches the materialized drain for every source shape" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var eng = try testEngine(gpa, io, "zig-cache/runadb-program-parity");
    defer eng.deinit();

    // Relation table.
    var cols = [_]value.Column{
        .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int },
        .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text },
    };
    defer for (&cols) |*column| column.deinit(gpa);
    try eng.createTable("customer", &cols);
    var ada: value.Value = .{ .text = try gpa.dupe(u8, "Ada") };
    defer ada.deinit(gpa);
    var lin: value.Value = .{ .text = try gpa.dupe(u8, "Lin") };
    defer lin.deinit(gpa);
    try eng.insert("customer", &.{ .{ .int = 1 }, ada });
    try eng.insert("customer", &.{ .{ .int = 2 }, lin });

    const sources = [_][]const u8{
        "from customer\n| emit { name, id }",
    };
    for (sources) |source| {
        var request = try bindSource(gpa, source);
        defer request.deinit(gpa);
        var prog = try open(gpa, &eng, &request, .{});
        defer prog.deinit();
        var batch: Batch = .{ .gpa = gpa };
        defer batch.deinit();
        var drained = try drainToRows(gpa, &prog, &batch, 1, std.math.maxInt(u64));
        defer drained.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 2), drained.rows.items.len);
        try std.testing.expectEqualStrings("Ada", drained.rows.items[0][0].?);
        try std.testing.expectEqualStrings("1", drained.rows.items[0][1].?);
        try std.testing.expectEqualStrings("Lin", drained.rows.items[1][0].?);
        try std.testing.expectEqualStrings("2", drained.rows.items[1][1].?);
    }

    // Observation evidence view.
    _ = try eng.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "test-camera", "development", "payload");
    var ev_request = try bindSource(gpa, "from observation_evidence\n| emit { object_id, modality, payload_length }");
    defer ev_request.deinit(gpa);
    var ev_prog = try open(gpa, &eng, &ev_request, .{});
    defer ev_prog.deinit();
    var ev_batch: Batch = .{ .gpa = gpa };
    defer ev_batch.deinit();
    var ev_drained = try drainToRows(gpa, &ev_prog, &ev_batch, 1, std.math.maxInt(u64));
    defer ev_drained.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), ev_drained.rows.items.len);
    try std.testing.expectEqualStrings("camera_1", ev_drained.rows.items[0][0].?);
    try std.testing.expectEqualStrings("image", ev_drained.rows.items[0][1].?);
    try std.testing.expectEqualStrings("7", ev_drained.rows.items[0][2].?);
}

test "the graph navigate program pre-resolves pairs and streams them in order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var eng = try testEngine(gpa, io, "zig-cache/runadb-program-navigate");
    defer eng.deinit();
    try eng.createGraph("social");
    var name: value.Value = .{ .text = try gpa.dupe(u8, "Ada") };
    defer name.deinit(gpa);
    const fields = [_]document_mod.Field{.{ .path = @constCast("name"), .item = name }};
    try eng.addNode("social", "1", &fields);
    try eng.addNode("social", "2", &fields);
    try eng.addEdge("social", "1", "mentors", "2");

    var request = try bindSource(gpa, "from social\n| navigate mentors as mentee\n| emit { name, mentee.name }");
    defer request.deinit(gpa);
    var prog = try open(gpa, &eng, &request, .{});
    defer prog.deinit();
    var batch: Batch = .{ .gpa = gpa };
    defer batch.deinit();
    var drained = try drainToRows(gpa, &prog, &batch, 1, std.math.maxInt(u64));
    defer drained.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), drained.rows.items.len);
    try std.testing.expectEqualStrings("Ada", drained.rows.items[0][0].?);
    try std.testing.expectEqualStrings("Ada", drained.rows.items[0][1].?);
}
