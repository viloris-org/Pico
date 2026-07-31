//! Bind and execute the initial read-only Runa Flow relation slice.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const engine_mod = @import("../storage/engine.zig");
const value = @import("../storage/value.zig");
const evidence = @import("../storage/evidence.zig");

pub const ExecError = ast.ParseError || ir.IrError || error{ SemanticNameNotFound, FieldNotFound, ModelRevisionMismatch } || Allocator.Error;

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
    if (std.mem.eql(u8, request.relation, "observation_evidence")) return executeEvidence(gpa, eng, request.fields);
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
    for (table.rows.items) |row| {
        const output = try gpa.alloc(?[]const u8, projection.len);
        errdefer gpa.free(output);
        for (projection, 0..) |column, output_index| output[output_index] = try valueToText(gpa, &owned_text, row.values[column]);
        try cells.append(gpa, output);
    }
    return .{ .columns = columns, .cells = try cells.toOwnedSlice(gpa), .owned_text = owned_text, .gpa = gpa };
}

const evidence_fields = [_][]const u8{
    "evidence_id",
    "object_id",
    "modality",
    "media_type",
    "observed_at",
    "origin",
    "owner",
    "payload_length",
    "payload_digest",
};

fn executeEvidence(gpa: Allocator, eng: *engine_mod.Engine, fields: []const []u8) !Result {
    const projection = try gpa.alloc(usize, fields.len);
    defer gpa.free(projection);
    for (fields, 0..) |field, output_index| {
        for (evidence_fields, 0..) |known, known_index| {
            if (std.mem.eql(u8, field, known)) {
                projection[output_index] = known_index;
                break;
            }
        } else return error.FieldNotFound;
    }
    const columns = try gpa.alloc([]const u8, fields.len);
    errdefer gpa.free(columns);
    for (projection, 0..) |field_index, index| columns[index] = evidence_fields[field_index];

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
    for (eng.observationsView()) |record| {
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
    }
    return .{ .columns = columns, .cells = try cells.toOwnedSlice(gpa), .owned_text = owned_text, .gpa = gpa };
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
