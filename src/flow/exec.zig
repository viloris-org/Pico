//! Bind and execute the initial read-only Runa Flow relation slice.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const engine_mod = @import("../storage/engine.zig");
const table_mod = @import("../storage/table.zig");
const value = @import("../storage/value.zig");
const evidence = @import("../storage/evidence.zig");

pub const ExecError = ast.ParseError || ir.IrError || error{
    SemanticNameNotFound,
    FieldNotFound,
    TypeMismatch,
    NonComparableColumn,
    ModelRevisionMismatch,
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

pub fn compile(gpa: Allocator, source: []const u8) !ir.Request {
    var parsed = try ast.parse(gpa, source);
    defer parsed.deinit(gpa);
    return ir.bind(gpa, parsed);
}

pub fn execute(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request) ExecError!Result {
    if (request.model_revision != ir.DEVELOPMENT_MODEL_REVISION) return error.ModelRevisionMismatch;
    if (request.operation != .emit) return error.InvalidOperation;
    // Read Committed: a Request observes the committed state at the current
    // published watermark. The in-memory tables hold one committed version per
    // row, so the live state is the latest committed state; version retention
    // for reads over older snapshots arrives with LSM storage (Phase 5).
    _ = eng.publishedSeq();
    if (std.mem.eql(u8, request.relation, "observation_evidence")) return executeEvidence(gpa, eng, request);
    // Revision 0 is an explicit development binding of relation names to the
    // existing table catalog. It is read-only and is not persisted as a model.
    const table = eng.getTable(request.relation) orelse return error.SemanticNameNotFound;
    const projection = try bindProjection(gpa, table, request.fields);
    defer gpa.free(projection);

    const columns = try gpa.alloc([]const u8, projection.len);
    errdefer gpa.free(columns);
    for (projection, 0..) |index, output_index| columns[output_index] = table.columns[index].name;

    var owned_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_text.items) |text| gpa.free(text);
        owned_text.deinit(gpa);
    }
    var cells: std.ArrayList([]?[]const u8) = .empty;
    errdefer {
        for (cells.items) |row| gpa.free(row);
        cells.deinit(gpa);
    }

    var bound = try bindTableWhere(gpa, table, request.where);
    defer bound.deinit();
    const indices = try table.matchIndices(gpa, bound.preds);
    defer gpa.free(indices);

    const max_rows: usize = if (request.limit) |limit| @intCast(limit) else std.math.maxInt(usize);
    var emitted: usize = 0;
    for (indices) |row_index| {
        if (emitted >= max_rows) break;
        const output = try gpa.alloc(?[]const u8, projection.len);
        errdefer gpa.free(output);
        for (projection, 0..) |column, output_index| output[output_index] = try valueToText(gpa, &owned_text, table.rows.items[row_index].values[column]);
        try cells.append(gpa, output);
        emitted += 1;
    }
    return .{ .columns = columns, .cells = try cells.toOwnedSlice(gpa), .owned_text = owned_text, .gpa = gpa };
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

fn executeEvidence(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request) !Result {
    const projection = try gpa.alloc(usize, request.fields.len);
    defer gpa.free(projection);
    for (request.fields, 0..) |field, output_index| {
        projection[output_index] = evidenceFieldIndex(field) orelse return error.FieldNotFound;
    }
    const columns = try gpa.alloc([]const u8, request.fields.len);
    errdefer gpa.free(columns);
    for (projection, 0..) |field_index, index| columns[index] = evidence_fields[field_index].name;

    var owned_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_text.items) |text| gpa.free(text);
        owned_text.deinit(gpa);
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
        .text => |text| return text,
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
