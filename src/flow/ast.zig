//! Source-oriented AST for the initial read-only Runa Flow relation slice.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    EmptyRequest,
    ExpectedFrom,
    ExpectedRelation,
    ExpectedEmit,
    ExpectedField,
    ExpectedOperator,
    ExpectedLiteral,
    ExpectedAlias,
    InvalidIdentifier,
    InvalidLiteral,
    InvalidLimit,
    UnsupportedStage,
} || Allocator.Error;

/// A single `| navigate <edge> as <alias>` stage: for each current node, follow
/// outgoing edges labeled `edge`; the destination node is addressable through
/// `<alias>.<path>` in the following emit.
pub const Navigate = struct {
    edge: []u8,
    alias: []u8,

    pub fn deinit(self: *Navigate, gpa: Allocator) void {
        gpa.free(self.edge);
        gpa.free(self.alias);
        self.* = undefined;
    }
};

pub const Source = struct {
    relation: []u8,
    where: []Predicate = &.{},
    navigate: ?Navigate = null,
    fields: [][]u8,
    limit: ?u32 = null,

    pub fn deinit(self: *Source, gpa: Allocator) void {
        gpa.free(self.relation);
        for (self.where) |*predicate| predicate.deinit(gpa);
        gpa.free(self.where);
        if (self.navigate) |*navigate| navigate.deinit(gpa);
        for (self.fields) |field| gpa.free(field);
        gpa.free(self.fields);
    }
};

/// A literal value written in Runa Flow source. Text is owned.
pub const Literal = union(enum) {
    int: i64,
    text: []u8,
    bool: bool,

    pub fn deinit(self: *Literal, gpa: Allocator) void {
        switch (self.*) {
            .text => |text| gpa.free(text),
            else => {},
        }
        self.* = undefined;
    }
};

/// A single `where` predicate. `scalar` carries the literal for scalar
/// operators; `list` carries the members for `in`/`not in`. `is null` and
/// `is not null` carry neither.
pub const Predicate = struct {
    column: []u8,
    op: Op,
    scalar: ?Literal = null,
    list: std.ArrayList(Literal) = .empty,

    pub fn deinit(self: *Predicate, gpa: Allocator) void {
        gpa.free(self.column);
        if (self.scalar) |*literal| literal.deinit(gpa);
        for (self.list.items) |*literal| literal.deinit(gpa);
        self.list.deinit(gpa);
        self.* = undefined;
    }
};

pub const Op = enum(u8) {
    eq = 1,
    neq = 2,
    lt = 3,
    gt = 4,
    lte = 5,
    gte = 6,
    is_null = 7,
    not_null = 8,
    in = 9,
    not_in = 10,
    like = 11,
    not_like = 12,
};

/// Parse the deliberately small initial grammar:
///
///     from relation
///     | where column = literal
///     | where column in ( literal, literal )
///     | where column is [not] null
///     | where column [not] like 'pattern'
///     | emit { field, field }
///     | limit non-negative-integer
///
/// Zero or more `where` stages may precede `emit`; they are AND-combined.
pub fn parse(gpa: Allocator, source: []const u8) ParseError!Source {
    var lines = std.mem.splitScalar(u8, source, '\n');
    const from_line = nextMeaningfulLine(&lines) orelse return error.EmptyRequest;
    const relation = try parseFrom(gpa, from_line);
    errdefer gpa.free(relation);

    var predicates: std.ArrayList(Predicate) = .empty;
    errdefer {
        for (predicates.items) |*predicate| predicate.deinit(gpa);
        predicates.deinit(gpa);
    }
    var navigate: ?Navigate = null;
    errdefer if (navigate) |*navigate_stage| navigate_stage.deinit(gpa);
    var fields: [][]u8 = undefined;
    var fields_allocated = false;
    while (!fields_allocated) {
        const line = nextMeaningfulLine(&lines) orelse break;
        if (std.mem.startsWith(u8, line, "| where ")) {
            try predicates.append(gpa, try parseWhere(gpa, line));
            continue;
        }
        if (std.mem.startsWith(u8, line, "| navigate ")) {
            if (navigate != null) return error.UnsupportedStage;
            navigate = try parseNavigate(gpa, line);
            continue;
        }
        if (std.mem.startsWith(u8, line, "| emit {")) {
            fields = try parseEmit(gpa, line);
            fields_allocated = true;
            continue;
        }
        return error.UnsupportedStage;
    }
    if (!fields_allocated) return error.ExpectedEmit;
    errdefer {
        for (fields) |field| gpa.free(field);
        gpa.free(fields);
    }
    const limit_line = nextMeaningfulLine(&lines);
    const limit = if (limit_line) |line| try parseLimit(line) else null;
    if (nextMeaningfulLine(&lines) != null) return error.UnsupportedStage;

    return .{
        .relation = relation,
        .where = try predicates.toOwnedSlice(gpa),
        .navigate = navigate,
        .fields = fields,
        .limit = limit,
    };
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
        if (!isPath(field)) return error.InvalidIdentifier;
        try fields.append(gpa, try gpa.dupe(u8, field));
    }
    return fields.toOwnedSlice(gpa);
}

/// Parse one `| navigate <edge> as <alias>` stage. `edge` and `alias` are
/// single identifiers in the initial graph slice.
fn parseNavigate(gpa: Allocator, line: []const u8) ParseError!Navigate {
    const prefix = "| navigate ";
    if (!std.mem.startsWith(u8, line, prefix)) return error.UnsupportedStage;
    const body = std.mem.trim(u8, line[prefix.len..], " \t");
    const as_index = std.mem.indexOf(u8, body, " as ") orelse return error.ExpectedAlias;
    const edge = std.mem.trim(u8, body[0..as_index], " \t");
    const alias = std.mem.trim(u8, body[as_index + " as ".len ..], " \t");
    if (edge.len == 0 or alias.len == 0) return error.ExpectedAlias;
    if (!isIdentifier(edge) or !isIdentifier(alias)) return error.InvalidIdentifier;
    return .{ .edge = try gpa.dupe(u8, edge), .alias = try gpa.dupe(u8, alias) };
}

fn parseLimit(line: []const u8) ParseError!u32 {
    const prefix = "| limit ";
    if (!std.mem.startsWith(u8, line, prefix)) return error.UnsupportedStage;
    const text = std.mem.trim(u8, line[prefix.len..], " \t");
    if (text.len == 0) return error.InvalidLimit;
    return std.fmt.parseInt(u32, text, 10) catch error.InvalidLimit;
}

/// Parse one `| where <predicate>` stage.
fn parseWhere(gpa: Allocator, line: []const u8) ParseError!Predicate {
    const prefix = "| where ";
    if (!std.mem.startsWith(u8, line, prefix)) return error.UnsupportedStage;
    const body = std.mem.trim(u8, line[prefix.len..], " \t");
    if (body.len == 0) return error.ExpectedOperator;

    const column_len = pathPrefixLength(body) orelse return error.InvalidIdentifier;
    const column = try gpa.dupe(u8, body[0..column_len]);
    errdefer gpa.free(column);
    const rest = std.mem.trim(u8, body[column_len..], " \t");

    if (std.mem.eql(u8, rest, "is null")) return .{ .column = column, .op = .is_null };
    if (std.mem.eql(u8, rest, "is not null")) return .{ .column = column, .op = .not_null };
    if (rest.len == 0) return error.ExpectedOperator;

    const cmp_ops = [_]struct { []const u8, Op }{
        .{ "!=", .neq },
        .{ "<=", .lte },
        .{ ">=", .gte },
        .{ "=", .eq },
        .{ "<", .lt },
        .{ ">", .gt },
    };
    for (cmp_ops) |entry| {
        if (std.mem.startsWith(u8, rest, entry[0])) {
            const value_text = std.mem.trim(u8, rest[entry[0].len..], " \t");
            if (value_text.len == 0) return error.ExpectedLiteral;
            return .{ .column = column, .op = entry[1], .scalar = try parseLiteral(gpa, value_text) };
        }
    }

    if (std.mem.startsWith(u8, rest, "not in")) {
        return .{ .column = column, .op = .not_in, .list = try parseInList(gpa, std.mem.trim(u8, rest["not in".len..], " \t")) };
    }
    if (std.mem.startsWith(u8, rest, "in")) {
        return .{ .column = column, .op = .in, .list = try parseInList(gpa, std.mem.trim(u8, rest["in".len..], " \t")) };
    }
    if (std.mem.startsWith(u8, rest, "not like")) {
        return .{ .column = column, .op = .not_like, .scalar = .{ .text = try parseQuoted(gpa, std.mem.trim(u8, rest["not like".len..], " \t")) } };
    }
    if (std.mem.startsWith(u8, rest, "like")) {
        return .{ .column = column, .op = .like, .scalar = .{ .text = try parseQuoted(gpa, std.mem.trim(u8, rest["like".len..], " \t")) } };
    }
    return error.ExpectedOperator;
}

fn parseInList(gpa: Allocator, text: []const u8) ParseError!std.ArrayList(Literal) {
    if (text.len < 2 or text[0] != '(' or text[text.len - 1] != ')') return error.ExpectedLiteral;
    const body = std.mem.trim(u8, text[1 .. text.len - 1], " \t");
    if (body.len == 0) return error.ExpectedLiteral;

    var list: std.ArrayList(Literal) = .empty;
    errdefer {
        for (list.items) |*item| item.deinit(gpa);
        list.deinit(gpa);
    }
    var parts = std.mem.splitScalar(u8, body, ',');
    while (parts.next()) |part| {
        const item = std.mem.trim(u8, part, " \t");
        if (item.len == 0) return error.ExpectedLiteral;
        try list.append(gpa, try parseLiteral(gpa, item));
    }
    return list;
}

fn parseLiteral(gpa: Allocator, text: []const u8) ParseError!Literal {
    if (text.len >= 2 and text[0] == '\'' and text[text.len - 1] == '\'') {
        return .{ .text = try gpa.dupe(u8, text[1 .. text.len - 1]) };
    }
    if (std.mem.eql(u8, text, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, text, "false")) return .{ .bool = false };
    const integer = std.fmt.parseInt(i64, text, 10) catch return error.InvalidLiteral;
    return .{ .int = integer };
}

fn parseQuoted(gpa: Allocator, text: []const u8) ParseError![]u8 {
    if (text.len < 2 or text[0] != '\'' or text[text.len - 1] != '\'') return error.InvalidLiteral;
    return gpa.dupe(u8, text[1 .. text.len - 1]);
}

/// Length of the path prefix of `text`, or null when `text` does not begin
/// with a path. A path is one or more identifiers joined by single dots
/// (`a`, `a.b`, `a.b.c`); a trailing dot is rejected.
fn pathPrefixLength(text: []const u8) ?usize {
    if (text.len == 0) return null;
    var index: usize = 0;
    while (true) {
        // One identifier segment. After a dot a further segment is required.
        if (index >= text.len) return null;
        if (!(std.ascii.isAlphabetic(text[index]) or text[index] == '_')) return null;
        index += 1;
        while (index < text.len and (std.ascii.isAlphanumeric(text[index]) or text[index] == '_')) index += 1;
        if (index < text.len and text[index] == '.') {
            index += 1;
            continue;
        }
        return index;
    }
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

/// A path is one or more identifiers joined by single dots (`a`, `a.b`). A
/// dotted path addresses a nested document field; a relation column is a path
/// of length one. The first and last byte must belong to an identifier segment
/// and no segment may be empty, so `a.` and `a..b` are rejected.
pub fn isPath(name: []const u8) bool {
    if (name.len == 0) return false;
    var segment_start: usize = 0;
    var i: usize = 0;
    while (i <= name.len) : (i += 1) {
        if (i == name.len or name[i] == '.') {
            if (!isIdentifier(name[segment_start..i])) return false;
            if (i == name.len) return true;
            segment_start = i + 1;
        }
    }
    return false;
}

test "parses a relation projection pipeline" {
    var parsed = try parse(std.testing.allocator, "from customer\n| emit { id, name }");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("customer", parsed.relation);
    try std.testing.expectEqual(@as(usize, 0), parsed.where.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.fields.len);
    try std.testing.expectEqualStrings("name", parsed.fields[1]);
}

test "rejects unimplemented stages" {
    try std.testing.expectError(error.UnsupportedStage, parse(std.testing.allocator, "from customer\n| emit { id }\n| rank id"));
}

test "parses a bounded relation flow" {
    var parsed = try parse(std.testing.allocator, "from customer\n| emit { id }\n| limit 12");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 12), parsed.limit);
}

test "rejects an invalid limit" {
    try std.testing.expectError(error.InvalidLimit, parse(std.testing.allocator, "from customer\n| emit { id }\n| limit -1"));
}

test "parses scalar where predicates" {
    var parsed = try parse(std.testing.allocator, "from customer\n| where id = 7\n| where name != 'ada'\n| where balance >= -5\n| where active = true\n| emit { id }");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), parsed.where.len);
    try std.testing.expectEqual(Op.eq, parsed.where[0].op);
    try std.testing.expectEqual(@as(i64, 7), parsed.where[0].scalar.?.int);
    try std.testing.expectEqual(Op.neq, parsed.where[1].op);
    try std.testing.expectEqualStrings("ada", parsed.where[1].scalar.?.text);
    try std.testing.expectEqual(Op.gte, parsed.where[2].op);
    try std.testing.expectEqual(@as(i64, -5), parsed.where[2].scalar.?.int);
    try std.testing.expectEqual(Op.eq, parsed.where[3].op);
    try std.testing.expectEqual(true, parsed.where[3].scalar.?.bool);
}

test "parses null, membership, and pattern where predicates" {
    var parsed = try parse(std.testing.allocator, "from customer\n| where region is null\n| where region is not null\n| where id in (1, 2, 3)\n| where id not in (4, 5)\n| where name like 'a%'\n| where name not like '_x'\n| emit { id }");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), parsed.where.len);
    try std.testing.expectEqual(Op.is_null, parsed.where[0].op);
    try std.testing.expectEqual(Op.not_null, parsed.where[1].op);
    try std.testing.expectEqual(Op.in, parsed.where[2].op);
    try std.testing.expectEqual(@as(usize, 3), parsed.where[2].list.items.len);
    try std.testing.expectEqual(@as(i64, 3), parsed.where[2].list.items[2].int);
    try std.testing.expectEqual(Op.not_in, parsed.where[3].op);
    try std.testing.expectEqual(Op.like, parsed.where[4].op);
    try std.testing.expectEqualStrings("a%", parsed.where[4].scalar.?.text);
    try std.testing.expectEqual(Op.not_like, parsed.where[5].op);
}

test "rejects malformed where predicates" {
    try std.testing.expectError(error.ExpectedOperator, parse(std.testing.allocator, "from customer\n| where id\n| emit { id }"));
    try std.testing.expectError(error.ExpectedLiteral, parse(std.testing.allocator, "from customer\n| where id =\n| emit { id }"));
    try std.testing.expectError(error.InvalidLiteral, parse(std.testing.allocator, "from customer\n| where id = active\n| emit { id }"));
    try std.testing.expectError(error.ExpectedLiteral, parse(std.testing.allocator, "from customer\n| where id in ()\n| emit { id }"));
    try std.testing.expectError(error.InvalidLiteral, parse(std.testing.allocator, "from customer\n| where name like bare\n| emit { id }"));
    try std.testing.expectError(error.InvalidIdentifier, parse(std.testing.allocator, "from customer\n| where 1 = id\n| emit { id }"));
}

test "rejects where stages after emit" {
    try std.testing.expectError(error.UnsupportedStage, parse(std.testing.allocator, "from customer\n| emit { id }\n| where id = 1"));
}
