const std = @import("std");
const Allocator = std.mem.Allocator;
const token = @import("token.zig");
const value = @import("../storage/value.zig");

pub const Stmt = union(enum) {
    create_table: CreateTable,
    insert: Insert,
    select: Select,
    empty,
};

pub const CreateTable = struct {
    name: []const u8,
    columns: []value.Column, // owned names
};

pub const Insert = struct {
    table: []const u8,
    columns: ?[][]const u8, // optional column list (borrowed)
    values: []value.Value, // owned
};

pub const Select = struct {
    table: []const u8,
    /// null means SELECT *
    columns: ?[][]const u8,
    /// optional WHERE <pk_col> = <int>
    where_pk: ?i64,
    where_col: ?[]const u8,
};

pub const ParseError = error{
    UnexpectedToken,
    UnterminatedString,
    UnexpectedChar,
    BadString,
    BadNumber,
    UnsupportedSyntax,
    MissingPrimaryKey,
} || Allocator.Error;

pub const Parser = struct {
    gpa: Allocator,
    lex: token.Lexer,
    cur: token.Token,

    pub fn init(gpa: Allocator, sql: []const u8) ParseError!Parser {
        var p: Parser = .{
            .gpa = gpa,
            .lex = .{ .src = sql },
            .cur = undefined,
        };
        p.cur = try p.lex.next();
        return p;
    }

    pub fn parseStatement(self: *Parser) ParseError!Stmt {
        self.skipSemis();
        if (self.cur.kind == .eof) return .empty;
        return switch (self.cur.kind) {
            .kw_create => self.parseCreateTable(),
            .kw_insert => self.parseInsert(),
            .kw_select => self.parseSelect(),
            else => error.UnsupportedSyntax,
        };
    }

    fn skipSemis(self: *Parser) void {
        while (self.cur.kind == .semicolon) {
            self.advance() catch return;
        }
    }

    fn advance(self: *Parser) ParseError!void {
        self.cur = try self.lex.next();
    }

    fn expect(self: *Parser, kind: token.TokenKind) ParseError!token.Token {
        if (self.cur.kind != kind) return error.UnexpectedToken;
        const t = self.cur;
        try self.advance();
        return t;
    }

    fn parseCreateTable(self: *Parser) ParseError!Stmt {
        _ = try self.expect(.kw_create);
        _ = try self.expect(.kw_table);
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.lparen);

        var cols: std.ArrayList(value.Column) = .empty;
        errdefer {
            for (cols.items) |*c| c.deinit(self.gpa);
            cols.deinit(self.gpa);
        }

        while (true) {
            const col_name = try self.expect(.ident);
            const type_tag = try self.parseType();
            var pk = false;
            if (self.cur.kind == .kw_primary) {
                try self.advance();
                _ = try self.expect(.kw_key);
                pk = true;
            }
            try cols.append(self.gpa, .{
                .name = try self.gpa.dupe(u8, col_name.text),
                .type_tag = type_tag,
                .primary_key = pk,
            });
            if (self.cur.kind == .comma) {
                try self.advance();
                continue;
            }
            break;
        }
        _ = try self.expect(.rparen);
        if (self.cur.kind == .semicolon) try self.advance();

        var has_pk = false;
        for (cols.items) |c| {
            if (c.primary_key) has_pk = true;
        }
        if (!has_pk) return error.MissingPrimaryKey;

        return .{ .create_table = .{
            .name = name_tok.text,
            .columns = try cols.toOwnedSlice(self.gpa),
        } };
    }

    fn parseType(self: *Parser) ParseError!value.TypeTag {
        const k = self.cur.kind;
        try self.advance();
        return switch (k) {
            .kw_int, .kw_integer => .int,
            .kw_text => .text,
            .kw_bool, .kw_boolean => .bool,
            else => error.UnexpectedToken,
        };
    }

    fn parseInsert(self: *Parser) ParseError!Stmt {
        _ = try self.expect(.kw_insert);
        _ = try self.expect(.kw_into);
        const table = try self.expect(.ident);

        var col_names: ?[][]const u8 = null;
        if (self.cur.kind == .lparen) {
            try self.advance();
            var names: std.ArrayList([]const u8) = .empty;
            errdefer names.deinit(self.gpa);
            while (true) {
                const n = try self.expect(.ident);
                try names.append(self.gpa, n.text);
                if (self.cur.kind == .comma) {
                    try self.advance();
                    continue;
                }
                break;
            }
            _ = try self.expect(.rparen);
            col_names = try names.toOwnedSlice(self.gpa);
        }

        _ = try self.expect(.kw_values);
        _ = try self.expect(.lparen);

        var vals: std.ArrayList(value.Value) = .empty;
        errdefer {
            for (vals.items) |*v| v.deinit(self.gpa);
            vals.deinit(self.gpa);
        }
        while (true) {
            try vals.append(self.gpa, try self.parseValue());
            if (self.cur.kind == .comma) {
                try self.advance();
                continue;
            }
            break;
        }
        _ = try self.expect(.rparen);
        if (self.cur.kind == .semicolon) try self.advance();

        return .{ .insert = .{
            .table = table.text,
            .columns = col_names,
            .values = try vals.toOwnedSlice(self.gpa),
        } };
    }

    fn parseValue(self: *Parser) ParseError!value.Value {
        switch (self.cur.kind) {
            .number => {
                const n = std.fmt.parseInt(i64, self.cur.text, 10) catch return error.BadNumber;
                try self.advance();
                return .{ .int = n };
            },
            .string => {
                const s = try token.unquoteString(self.gpa, self.cur.text);
                try self.advance();
                return .{ .text = s };
            },
            .ident => {
                if (token.eqlIgnoreCase(self.cur.text, "TRUE")) {
                    try self.advance();
                    return .{ .bool = true };
                }
                if (token.eqlIgnoreCase(self.cur.text, "FALSE")) {
                    try self.advance();
                    return .{ .bool = false };
                }
                if (token.eqlIgnoreCase(self.cur.text, "NULL")) {
                    try self.advance();
                    return .null;
                }
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn parseSelect(self: *Parser) ParseError!Stmt {
        _ = try self.expect(.kw_select);
        var cols: ?[][]const u8 = null;
        if (self.cur.kind == .star) {
            try self.advance();
        } else {
            var names: std.ArrayList([]const u8) = .empty;
            errdefer names.deinit(self.gpa);
            while (true) {
                const n = try self.expect(.ident);
                try names.append(self.gpa, n.text);
                if (self.cur.kind == .comma) {
                    try self.advance();
                    continue;
                }
                break;
            }
            cols = try names.toOwnedSlice(self.gpa);
        }
        _ = try self.expect(.kw_from);
        const table = try self.expect(.ident);

        var where_pk: ?i64 = null;
        var where_col: ?[]const u8 = null;
        if (self.cur.kind == .kw_where) {
            try self.advance();
            const col = try self.expect(.ident);
            _ = try self.expect(.eq);
            const num = try self.expect(.number);
            where_pk = std.fmt.parseInt(i64, num.text, 10) catch return error.BadNumber;
            where_col = col.text;
        }
        if (self.cur.kind == .semicolon) try self.advance();

        return .{ .select = .{
            .table = table.text,
            .columns = cols,
            .where_pk = where_pk,
            .where_col = where_col,
        } };
    }
};

pub fn freeStmt(gpa: Allocator, stmt: *Stmt) void {
    switch (stmt.*) {
        .create_table => |*ct| {
            for (ct.columns) |*c| c.deinit(gpa);
            gpa.free(ct.columns);
        },
        .insert => |*ins| {
            if (ins.columns) |c| gpa.free(c);
            for (ins.values) |*v| v.deinit(gpa);
            gpa.free(ins.values);
        },
        .select => |*sel| {
            if (sel.columns) |c| gpa.free(c);
        },
        .empty => {},
    }
    stmt.* = .empty;
}

test "parse create insert select" {
    const gpa = std.testing.allocator;
    {
        var p = try Parser.init(gpa, "CREATE TABLE users (id INT PRIMARY KEY, name TEXT);");
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt == .create_table);
        try std.testing.expectEqual(@as(usize, 2), stmt.create_table.columns.len);
    }
    {
        var p = try Parser.init(gpa, "INSERT INTO users (id, name) VALUES (1, 'alice');");
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt == .insert);
    }
    {
        var p = try Parser.init(gpa, "SELECT id, name FROM users WHERE id = 1");
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt == .select);
        try std.testing.expectEqual(@as(i64, 1), stmt.select.where_pk.?);
    }
}
