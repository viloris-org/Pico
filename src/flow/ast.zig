//! Source-oriented AST for the initial read-only Runa Flow relation slice.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    EmptyRequest,
    ExpectedFrom,
    ExpectedRelation,
    ExpectedEmit,
    ExpectedField,
    InvalidIdentifier,
    UnsupportedStage,
} || Allocator.Error;

pub const Source = struct {
    relation: []u8,
    fields: [][]u8,

    pub fn deinit(self: *Source, gpa: Allocator) void {
        gpa.free(self.relation);
        for (self.fields) |field| gpa.free(field);
        gpa.free(self.fields);
    }
};

/// Parse the deliberately small initial grammar:
///
///     from relation
///     | emit { field, field }
pub fn parse(gpa: Allocator, source: []const u8) ParseError!Source {
    var lines = std.mem.splitScalar(u8, source, '\n');
    const from_line = nextMeaningfulLine(&lines) orelse return error.EmptyRequest;
    const relation = try parseFrom(gpa, from_line);
    errdefer gpa.free(relation);

    const emit_line = nextMeaningfulLine(&lines) orelse return error.ExpectedEmit;
    const fields = try parseEmit(gpa, emit_line);
    errdefer {
        for (fields) |field| gpa.free(field);
        gpa.free(fields);
    }
    if (nextMeaningfulLine(&lines) != null) return error.UnsupportedStage;

    return .{ .relation = relation, .fields = fields };
}

fn nextMeaningfulLine(lines: anytype) ?[]const u8 {
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len != 0) return line;
    }
    return null;
}

fn parseFrom(gpa: Allocator, line: []const u8) ParseError![]u8 {
    const prefix = "from ";
    if (!std.mem.startsWith(u8, line, prefix)) return error.ExpectedFrom;
    const name = std.mem.trim(u8, line[prefix.len..], " \t");
    if (name.len == 0) return error.ExpectedRelation;
    if (!isIdentifier(name)) return error.InvalidIdentifier;
    return gpa.dupe(u8, name);
}

fn parseEmit(gpa: Allocator, line: []const u8) ParseError![][]u8 {
    const prefix = "| emit {";
    if (!std.mem.startsWith(u8, line, prefix) or line.len < prefix.len + 1 or line[line.len - 1] != '}') return error.ExpectedEmit;
    const body = std.mem.trim(u8, line[prefix.len .. line.len - 1], " \t");
    if (body.len == 0) return error.ExpectedField;

    var fields: std.ArrayList([]u8) = .empty;
    errdefer {
        for (fields.items) |field| gpa.free(field);
        fields.deinit(gpa);
    }
    var parts = std.mem.splitScalar(u8, body, ',');
    while (parts.next()) |part| {
        const field = std.mem.trim(u8, part, " \t");
        if (field.len == 0) return error.ExpectedField;
        if (!isIdentifier(field)) return error.InvalidIdentifier;
        try fields.append(gpa, try gpa.dupe(u8, field));
    }
    return fields.toOwnedSlice(gpa);
}

/// An identifier is deliberately ASCII-only in the initial development slice.
/// Keep this shared with IR validation so decoded requests cannot name values
/// that Runa Flow source could never produce.
pub fn isIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

test "parses a relation projection pipeline" {
    var parsed = try parse(std.testing.allocator, "from customer\n| emit { id, name }");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("customer", parsed.relation);
    try std.testing.expectEqual(@as(usize, 2), parsed.fields.len);
    try std.testing.expectEqualStrings("name", parsed.fields[1]);
}

test "rejects unimplemented stages" {
    try std.testing.expectError(error.UnsupportedStage, parse(std.testing.allocator, "from customer\n| emit { id }\n| limit 1"));
}
