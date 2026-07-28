const std = @import("std");
const Allocator = std.mem.Allocator;
const token = @import("token.zig");
const value = @import("../storage/value.zig");
const ast = @import("ast.zig");

pub const Stmt = ast.Stmt;
pub const AlterTable = ast.AlterTable;
pub const CreateTable = ast.CreateTable;
pub const CreateIndex = ast.CreateIndex;
pub const Insert = ast.Insert;
pub const Predicate = ast.Predicate;
pub const Select = ast.Select;
pub const OrderTerm = ast.OrderTerm;
pub const SetClause = ast.SetClause;
pub const Update = ast.Update;
pub const Delete = ast.Delete;
pub const formatNow = ast.formatNow;
pub const freeStmt = ast.freeStmt;

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
    /// Owned identifier strings produced while parsing one statement.
    owned_idents: std.ArrayList([]u8),

    pub fn init(gpa: Allocator, sql: []const u8) ParseError!Parser {
        var p: Parser = .{
            .gpa = gpa,
            .lex = .{ .src = sql },
            .cur = undefined,
            .owned_idents = .empty,
        };
        p.cur = try p.lex.next();
        return p;
    }

    pub fn deinit(self: *Parser) void {
        for (self.owned_idents.items) |s| self.gpa.free(s);
        self.owned_idents.deinit(self.gpa);
    }

    pub fn parseStatement(self: *Parser) ParseError!Stmt {
        self.skipSemis();
        if (self.cur.kind == .eof) return .empty;
        return switch (self.cur.kind) {
            .kw_create => self.parseCreate(),
            .kw_alter => self.parseAlter(),
            .kw_insert => self.parseInsert(),
            .kw_select => self.parseSelect(),
            .kw_update => self.parseUpdate(),
            .kw_delete => self.parseDelete(),
            .kw_begin => {
                try self.advance();
                // optional TRANSACTION keyword as bare ident
                if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "TRANSACTION")) {
                    try self.advance();
                }
                if (self.cur.kind == .semicolon) try self.advance();
                return .begin_tx;
            },
            .kw_commit => {
                try self.advance();
                if (self.cur.kind == .semicolon) try self.advance();
                return .commit_tx;
            },
            .kw_rollback => {
                try self.advance();
                if (self.cur.kind == .semicolon) try self.advance();
                return .rollback_tx;
            },
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

    fn parseIdent(self: *Parser) ParseError![]const u8 {
        // PostgreSQL allows many keywords as unquoted identifiers (e.g. column "key").
        if (!isIdentLike(self.cur.kind)) return error.UnexpectedToken;
        const t = self.cur;
        try self.advance();
        if (t.text.len >= 2 and t.text[0] == '"') {
            const s = try token.unquoteString(self.gpa, t.text);
            try self.owned_idents.append(self.gpa, s);
            return s;
        }
        return t.text;
    }

    fn parseCreate(self: *Parser) ParseError!Stmt {
        _ = try self.expect(.kw_create);
        if (self.cur.kind == .kw_index) {
            try self.advance();
            return self.parseCreateIndex(false);
        }
        if (self.cur.kind == .kw_unique) {
            try self.advance();
            _ = try self.expect(.kw_index);
            return self.parseCreateIndex(true);
        }
        _ = try self.expect(.kw_table);

        var if_not_exists = false;
        if (self.cur.kind == .kw_if) {
            try self.advance();
            _ = try self.expect(.kw_not);
            _ = try self.expect(.kw_exists);
            if_not_exists = true;
        }

        const name = try self.parseIdent();
        _ = try self.expect(.lparen);

        var cols: std.ArrayList(value.Column) = .empty;
        errdefer {
            for (cols.items) |*c| c.deinit(self.gpa);
            cols.deinit(self.gpa);
        }

        // Table-level PRIMARY KEY column names (borrowed), applied after column list.
        var table_pk_cols: std.ArrayList([]const u8) = .empty;
        defer table_pk_cols.deinit(self.gpa);

        while (true) {
            // Table-level constraints
            if (self.cur.kind == .kw_primary) {
                try self.advance();
                _ = try self.expect(.kw_key);
                _ = try self.expect(.lparen);
                while (true) {
                    const c = try self.parseIdent();
                    try table_pk_cols.append(self.gpa, c);
                    if (self.cur.kind == .comma) {
                        try self.advance();
                        continue;
                    }
                    break;
                }
                _ = try self.expect(.rparen);
                if (self.cur.kind == .comma) {
                    try self.advance();
                    continue;
                }
                break;
            }
            // Table constraints other than PRIMARY KEY do not yet have storage
            // semantics. Reject them rather than accepting a no-op definition.
            if (self.cur.kind == .kw_unique or self.cur.kind == .kw_references or self.cur.kind == .kw_check or
                (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "FOREIGN")) or
                (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "CONSTRAINT")))
            {
                return error.UnsupportedSyntax;
            }

            try cols.append(self.gpa, try self.parseColumnDef());
            if (self.cur.kind == .comma) {
                try self.advance();
                continue;
            }
            break;
        }
        _ = try self.expect(.rparen);
        if (self.cur.kind == .semicolon) try self.advance();

        // Apply a single-column table PRIMARY KEY. Composite keys are not
        // accepted until their uniqueness and WAL semantics are implemented.
        if (table_pk_cols.items.len > 1) return error.UnsupportedSyntax;
        if (table_pk_cols.items.len == 1) {
            const pk_name = table_pk_cols.items[0];
            var found = false;
            for (cols.items) |*c| {
                if (token.eqlIgnoreCase(c.name, pk_name)) {
                    c.primary_key = true;
                    c.not_null = true;
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnexpectedToken;
        }

        var has_pk = false;
        for (cols.items) |c| {
            if (c.primary_key) has_pk = true;
        }
        if (!has_pk and table_pk_cols.items.len == 0) return error.MissingPrimaryKey;

        return .{ .create_table = .{
            .name = name,
            .columns = try cols.toOwnedSlice(self.gpa),
            .if_not_exists = if_not_exists,
        } };
    }

    fn parseAlter(self: *Parser) ParseError!Stmt {
        _ = try self.expect(.kw_alter);
        _ = try self.expect(.kw_table);
        const table = try self.parseIdent();
        if (self.cur.kind == .kw_add) {
            try self.advance();
            if (self.cur.kind == .kw_column) try self.advance();
            var if_not_exists = false;
            if (self.cur.kind == .kw_if) {
                try self.advance();
                _ = try self.expect(.kw_not);
                _ = try self.expect(.kw_exists);
                if_not_exists = true;
            }
            const column = try self.parseColumnDef();
            if (self.cur.kind == .semicolon) try self.advance();
            return .{ .alter_table = .{ .table = table, .action = .{ .add_column = .{ .column = column, .if_not_exists = if_not_exists } } } };
        }
        if (self.cur.kind == .kw_drop) {
            try self.advance();
            if (self.cur.kind == .kw_column) try self.advance();
            if (self.cur.kind == .kw_default) {
                try self.advance();
                if (self.cur.kind == .semicolon) try self.advance();
                return error.UnexpectedToken;
            }
            var if_exists = false;
            if (self.cur.kind == .kw_if) {
                try self.advance();
                _ = try self.expect(.kw_exists);
                if_exists = true;
            }
            const name = try self.parseIdent();
            if (self.cur.kind == .semicolon) try self.advance();
            return .{ .alter_table = .{ .table = table, .action = .{ .drop_column = .{ .name = name, .if_exists = if_exists } } } };
        }
        if (self.cur.kind == .kw_alter) try self.advance();
        if (self.cur.kind == .kw_column) try self.advance();
        const column = try self.parseIdent();
        if (self.cur.kind == .kw_set) {
            try self.advance();
            if (self.cur.kind == .kw_default) {
                try self.advance();
                const default_expr = try self.parseDefaultExpr();
                if (self.cur.kind == .semicolon) try self.advance();
                return .{ .alter_table = .{ .table = table, .action = .{ .set_default = .{ .column = column, .default_expr = default_expr } } } };
            }
            _ = try self.expect(.kw_not);
            _ = try self.expect(.kw_null);
            if (self.cur.kind == .semicolon) try self.advance();
            return .{ .alter_table = .{ .table = table, .action = .{ .set_not_null = .{ .column = column } } } };
        }
        _ = try self.expect(.kw_drop);
        if (self.cur.kind == .kw_default) {
            try self.advance();
            if (self.cur.kind == .semicolon) try self.advance();
            return .{ .alter_table = .{ .table = table, .action = .{ .drop_default = .{ .column = column } } } };
        }
        _ = try self.expect(.kw_not);
        _ = try self.expect(.kw_null);
        if (self.cur.kind == .semicolon) try self.advance();
        return .{ .alter_table = .{ .table = table, .action = .{ .drop_not_null = .{ .column = column } } } };
    }

    fn parseCreateIndex(self: *Parser, is_unique: bool) ParseError!Stmt {
        _ = self;
        _ = is_unique;
        return error.UnsupportedSyntax;
    }

    fn skipUntilStmtEnd(self: *Parser) ParseError!void {
        var depth: i32 = 0;
        while (self.cur.kind != .eof) {
            if (self.cur.kind == .lparen) depth += 1;
            if (self.cur.kind == .rparen) depth -= 1;
            if (self.cur.kind == .semicolon and depth <= 0) return;
            try self.advance();
        }
    }

    fn skipBalancedConstraint(self: *Parser) ParseError!void {
        // Consume tokens until comma or rparen at depth 0 (relative to start).
        var depth: i32 = 0;
        // Always consume at least the first token.
        try self.advance();
        while (self.cur.kind != .eof) {
            if (self.cur.kind == .lparen) {
                depth += 1;
                try self.advance();
                continue;
            }
            if (self.cur.kind == .rparen) {
                if (depth == 0) return;
                depth -= 1;
                try self.advance();
                continue;
            }
            if (self.cur.kind == .comma and depth == 0) return;
            try self.advance();
        }
    }

    fn parseColumnDef(self: *Parser) ParseError!value.Column {
        const col_name = try self.parseIdent();
        const type_info = try self.parseType();

        var col: value.Column = .{
            .name = try self.gpa.dupe(u8, col_name),
            .type_tag = type_info.tag,
            .primary_key = false,
            .not_null = type_info.serial, // SERIAL is NOT NULL
            .unique = false,
            .serial = type_info.serial,
            .default_expr = .none,
        };
        errdefer col.deinit(self.gpa);

        // Column constraints in any order
        while (true) {
            switch (self.cur.kind) {
                .kw_primary => {
                    try self.advance();
                    _ = try self.expect(.kw_key);
                    col.primary_key = true;
                    col.not_null = true;
                },
                .kw_not => {
                    try self.advance();
                    _ = try self.expect(.kw_null);
                    col.not_null = true;
                },
                .kw_null => {
                    try self.advance();
                    // explicit NULL — no-op
                },
                .kw_unique => {
                    try self.advance();
                    col.unique = true;
                },
                .kw_default => {
                    try self.advance();
                    col.default_expr.deinit(self.gpa);
                    col.default_expr = try self.parseDefaultExpr();
                },
                .kw_references => {
                    return error.UnsupportedSyntax;
                },
                .kw_check => {
                    return error.UnsupportedSyntax;
                },
                else => break,
            }
        }
        return col;
    }

    const TypeInfo = struct {
        tag: value.TypeTag,
        serial: bool,
    };

    fn parseType(self: *Parser) ParseError!TypeInfo {
        // DOUBLE PRECISION (two-word type)
        if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "DOUBLE")) {
            try self.advance();
            if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "PRECISION")) {
                try self.advance();
            }
            return .{ .tag = .text, .serial = false };
        }

        const k = self.cur.kind;
        const info: TypeInfo = switch (k) {
            .kw_int, .kw_integer, .kw_bigint, .kw_smallint => .{ .tag = .int, .serial = false },
            .kw_serial, .kw_bigserial => .{ .tag = .int, .serial = true },
            .kw_text, .kw_varchar, .kw_char, .kw_decimal, .kw_numeric, .kw_timestamp, .kw_timestamptz, .kw_date, .kw_json, .kw_jsonb => .{ .tag = .text, .serial = false },
            .kw_bool, .kw_boolean => .{ .tag = .bool, .serial = false },
            else => return error.UnexpectedToken,
        };
        try self.advance();

        // Optional precision: VARCHAR(100), DECIMAL(20,8), TIMESTAMP(3)
        if (self.cur.kind == .lparen) {
            try self.advance();
            if (self.cur.kind == .number or self.cur.kind == .float) try self.advance();
            if (self.cur.kind == .comma) {
                try self.advance();
                if (self.cur.kind == .number or self.cur.kind == .float) try self.advance();
            }
            _ = try self.expect(.rparen);
        }

        // TIMESTAMP WITH TIME ZONE / WITHOUT TIME ZONE
        if (k == .kw_timestamp or k == .kw_timestamptz) {
            if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "WITH")) {
                try self.advance();
                if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "TIME")) try self.advance();
                if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "ZONE")) try self.advance();
            } else if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "WITHOUT")) {
                try self.advance();
                if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "TIME")) try self.advance();
                if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "ZONE")) try self.advance();
            }
        }

        // Array suffix type[] — stored as text (no array ops yet).
        var result = info;
        if (self.cur.kind == .lbracket) {
            try self.advance();
            _ = try self.expect(.rbracket);
            result.tag = .text;
            result.serial = false;
        }

        return result;
    }

    fn parseDefaultExpr(self: *Parser) ParseError!value.DefaultExpr {
        if (self.cur.kind == .kw_now) {
            try self.advance();
            if (self.cur.kind == .lparen) {
                try self.advance();
                _ = try self.expect(.rparen);
            }
            return .now;
        }
        // CURRENT_TIMESTAMP as ident
        if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "CURRENT_TIMESTAMP")) {
            try self.advance();
            return .now;
        }
        if (self.cur.kind == .kw_null) {
            try self.advance();
            return .{ .literal = .null };
        }
        const v = try self.parseValue();
        // Optional ::type cast after default literal
        if (self.cur.kind == .double_colon) {
            try self.advance();
            // skip type name and optional precision
            if (isTypeKeyword(self.cur.kind) or self.cur.kind == .ident) try self.advance();
            if (self.cur.kind == .lparen) {
                try self.advance();
                if (self.cur.kind == .number or self.cur.kind == .float) try self.advance();
                if (self.cur.kind == .comma) {
                    try self.advance();
                    if (self.cur.kind == .number or self.cur.kind == .float) try self.advance();
                }
                _ = try self.expect(.rparen);
            }
        }
        return .{ .literal = v };
    }

    fn skipReferences(self: *Parser) ParseError!void {
        // REFERENCES table (cols) [ON DELETE ...] [ON UPDATE ...]
        _ = try self.expect(.kw_references);
        _ = try self.parseIdent();
        if (self.cur.kind == .lparen) {
            try self.advance();
            while (true) {
                _ = try self.parseIdent();
                if (self.cur.kind == .comma) {
                    try self.advance();
                    continue;
                }
                break;
            }
            _ = try self.expect(.rparen);
        }
        while (self.cur.kind == .kw_on) {
            try self.advance();
            // DELETE / UPDATE as ident or we don't have kw_update in this position — UPDATE is kw_update
            if (self.cur.kind == .kw_delete or self.cur.kind == .kw_update or self.cur.kind == .ident) {
                try self.advance();
            } else return error.UnexpectedToken;
            // SET NULL | CASCADE | RESTRICT | NO ACTION | SET DEFAULT
            if (self.cur.kind == .kw_set) {
                try self.advance();
                if (self.cur.kind == .kw_null or self.cur.kind == .kw_default) {
                    try self.advance();
                } else return error.UnexpectedToken;
            } else if (self.cur.kind == .kw_cascade or self.cur.kind == .kw_restrict) {
                try self.advance();
            } else if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "NO")) {
                try self.advance();
                if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "ACTION")) try self.advance();
            } else {
                return error.UnexpectedToken;
            }
        }
    }

    fn parseInsert(self: *Parser) ParseError!Stmt {
        _ = try self.expect(.kw_insert);
        _ = try self.expect(.kw_into);
        const table = try self.parseIdent();

        var col_names: ?[][]const u8 = null;
        if (self.cur.kind == .lparen) {
            try self.advance();
            var names: std.ArrayList([]const u8) = .empty;
            errdefer names.deinit(self.gpa);
            while (true) {
                const n = try self.parseIdent();
                try names.append(self.gpa, n);
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
        var rows: std.ArrayList([]value.Value) = .empty;
        errdefer {
            if (col_names) |cn| self.gpa.free(cn);
            for (rows.items) |row| {
                for (row) |*v| v.deinit(self.gpa);
                self.gpa.free(row);
            }
            rows.deinit(self.gpa);
        }
        while (true) {
            _ = try self.expect(.lparen);
            var vals: std.ArrayList(value.Value) = .empty;
            errdefer {
                for (vals.items) |*v| v.deinit(self.gpa);
                vals.deinit(self.gpa);
            }
            while (true) {
                try vals.append(self.gpa, try self.parseValue());
                // optional ::cast
                if (self.cur.kind == .double_colon) {
                    try self.advance();
                    if (isTypeKeyword(self.cur.kind) or self.cur.kind == .ident) try self.advance();
                    if (self.cur.kind == .lparen) {
                        try self.advance();
                        if (self.cur.kind == .number or self.cur.kind == .float) try self.advance();
                        if (self.cur.kind == .comma) {
                            try self.advance();
                            if (self.cur.kind == .number or self.cur.kind == .float) try self.advance();
                        }
                        _ = try self.expect(.rparen);
                    }
                }
                if (self.cur.kind == .comma) {
                    try self.advance();
                    continue;
                }
                break;
            }
            _ = try self.expect(.rparen);
            try rows.append(self.gpa, try vals.toOwnedSlice(self.gpa));
            if (self.cur.kind != .comma) break;
            try self.advance();
            if (self.cur.kind != .lparen) return error.UnexpectedToken;
        }
        // RETURNING needs the rows produced by the write path; accepting it
        // before that exists would report a successful statement with lost data.
        if (self.cur.kind == .ident and token.eqlIgnoreCase(self.cur.text, "RETURNING")) {
            return error.UnsupportedSyntax;
        }
        // ON CONFLICT must be rejected before the Insert is returned. Accepting
        // it here lets the INSERT execute (autocommit path), then the leftover
        // tokens error on the next parseStatement() — a data-integrity leak.
        if (self.cur.kind == .kw_on) {
            return error.UnsupportedSyntax;
        }
        if (self.cur.kind == .semicolon) try self.advance();

        return .{ .insert = .{
            .table = table,
            .columns = col_names,
            .rows = try rows.toOwnedSlice(self.gpa),
        } };
    }

    fn parseValue(self: *Parser) ParseError!value.Value {
        switch (self.cur.kind) {
            .number => {
                const n = std.fmt.parseInt(i64, self.cur.text, 10) catch return error.BadNumber;
                try self.advance();
                return .{ .int = n };
            },
            .float => {
                // Store decimal literals as text for DECIMAL/NUMERIC columns.
                const s = try self.gpa.dupe(u8, self.cur.text);
                try self.advance();
                return .{ .text = s };
            },
            .string => {
                const s = try token.unquoteString(self.gpa, self.cur.text);
                try self.advance();
                return .{ .text = s };
            },
            .kw_true => {
                try self.advance();
                return .{ .bool = true };
            },
            .kw_false => {
                try self.advance();
                return .{ .bool = false };
            },
            .kw_null => {
                try self.advance();
                return .null;
            },
            .kw_now => {
                try self.advance();
                if (self.cur.kind == .lparen) {
                    try self.advance();
                    _ = try self.expect(.rparen);
                }
                const s = try formatNow(self.gpa);
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
                if (token.eqlIgnoreCase(self.cur.text, "CURRENT_TIMESTAMP")) {
                    try self.advance();
                    const s = try formatNow(self.gpa);
                    return .{ .text = s };
                }
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn parseWhere(self: *Parser) ParseError![]Predicate {
        var preds: std.ArrayList(Predicate) = .empty;
        errdefer {
            for (preds.items) |*p| p.deinit(self.gpa);
            preds.deinit(self.gpa);
        }
        while (true) {
            if (self.cur.kind == .lparen) {
                try preds.append(self.gpa, try self.parseOrGroup());
            } else {
                try preds.append(self.gpa, try self.parsePredicate());
            }
            if (self.cur.kind == .kw_and) {
                try self.advance();
                continue;
            }
            // OR outside parentheses is not supported yet (requires full precedence handling)
            if (self.cur.kind == .kw_or) return error.UnsupportedSyntax;
            break;
        }
        return try preds.toOwnedSlice(self.gpa);
    }

    /// Parse a parenthesized OR group: (pred1 AND ... OR pred2 AND ...)
    fn parseOrGroup(self: *Parser) ParseError!Predicate {
        _ = try self.expect(.lparen);
        var groups: std.ArrayList([]Predicate) = .empty;
        errdefer {
            for (groups.items) |g| {
                for (g) |*p| p.deinit(self.gpa);
                self.gpa.free(g);
            }
            groups.deinit(self.gpa);
        }
        while (true) {
            var group: std.ArrayList(Predicate) = .empty;
            errdefer {
                for (group.items) |*p| p.deinit(self.gpa);
                group.deinit(self.gpa);
            }
            while (true) {
                try group.append(self.gpa, try self.parsePredicate());
                if (self.cur.kind == .kw_and) {
                    try self.advance();
                    continue;
                }
                break;
            }
            try groups.append(self.gpa, try group.toOwnedSlice(self.gpa));
            if (self.cur.kind == .kw_or) {
                try self.advance();
                continue;
            }
            break;
        }
        _ = try self.expect(.rparen);
        return .{ .or_group = .{ .groups = try groups.toOwnedSlice(self.gpa) } };
    }

    fn parsePredicate(self: *Parser) ParseError!Predicate {
        // NOT prefix: parse inner predicate and invert it
        if (self.cur.kind == .kw_not) {
            try self.advance();
            const inner = try self.parsePredicate();
            return switch (inner) {
                .eq => |e| Predicate{
                    .cmp = .{
                        .column = e.column,
                        .column_owned = e.column_owned,
                        .op = .neq,
                        .value = e.value,
                    },
                },
                .cmp => |c| blk: {
                    if (c.op == .neq) {
                        break :blk Predicate{
                            .eq = .{
                                .column = c.column,
                                .column_owned = c.column_owned,
                                .value = c.value,
                            },
                        };
                    }
                    const inverted: Predicate.CmpOp = switch (c.op) {
                        .lt => .gte,
                        .gt => .lte,
                        .lte => .gt,
                        .gte => .lt,
                        else => unreachable,
                    };
                    break :blk Predicate{
                        .cmp = .{
                            .column = c.column,
                            .column_owned = c.column_owned,
                            .op = inverted,
                            .value = c.value,
                        },
                    };
                },
                .is_null => |n| Predicate{
                    .is_null = .{
                        .column = n.column,
                        .column_owned = n.column_owned,
                        .negated = !n.negated,
                    },
                },
                .or_group => error.UnsupportedSyntax,
            };
        }
        const col = try self.parseIdent();
        if (self.cur.kind == .kw_is) {
            try self.advance();
            var negated = false;
            if (self.cur.kind == .kw_not) {
                try self.advance();
                negated = true;
            }
            _ = try self.expect(.kw_null);
            return .{ .is_null = .{ .column = col, .negated = negated } };
        }
        // comparison
        const op = self.cur.kind;
        if (op != .eq and op != .neq and op != .lt and op != .gt and op != .lte and op != .gte) {
            return error.UnexpectedToken;
        }
        try self.advance();
        if (op == .eq) {
            const val = try self.parseValue();
            if (self.cur.kind == .double_colon) {
                try self.advance();
                if (isTypeKeyword(self.cur.kind) or self.cur.kind == .ident) try self.advance();
            }
            return .{ .eq = .{ .column = col, .value = val } };
        }
        const val = try self.parseValue();
        if (self.cur.kind == .double_colon) {
            try self.advance();
            if (isTypeKeyword(self.cur.kind) or self.cur.kind == .ident) try self.advance();
        }
        const cmp_op: Predicate.CmpOp = switch (op) {
            .neq => .neq,
            .lt => .lt,
            .gt => .gt,
            .lte => .lte,
            .gte => .gte,
            else => unreachable,
        };
        return .{ .cmp = .{ .column = col, .op = cmp_op, .value = val } };
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
                const n = try self.parseIdent();
                // optional AS alias — ignore alias for projection name use alias if present
                if (self.cur.kind == .kw_as) {
                    try self.advance();
                    _ = try self.parseIdent();
                } else if (self.cur.kind == .ident) {
                    // bare alias
                    _ = try self.parseIdent();
                }
                try names.append(self.gpa, n);
                if (self.cur.kind == .comma) {
                    try self.advance();
                    continue;
                }
                break;
            }
            cols = try names.toOwnedSlice(self.gpa);
        }
        _ = try self.expect(.kw_from);
        const table = try self.parseIdent();

        const where_preds: []Predicate = if (self.cur.kind == .kw_where) blk: {
            try self.advance();
            break :blk try self.parseWhere();
        } else try self.gpa.alloc(Predicate, 0);
        errdefer {
            for (where_preds) |*wp| wp.deinit(self.gpa);
            self.gpa.free(where_preds);
        }

        var order_by: ?OrderTerm = null;
        if (self.cur.kind == .kw_order) {
            try self.advance();
            _ = try self.expect(.kw_by);
            const column = try self.parseIdent();
            var descending = false;
            if (self.cur.kind == .kw_asc) {
                try self.advance();
            } else if (self.cur.kind == .kw_desc) {
                try self.advance();
                descending = true;
            }
            // Keep the supported surface explicit until multi-key sort has
            // deterministic semantics and coverage.
            if (self.cur.kind == .comma) return error.UnsupportedSyntax;
            order_by = .{ .column = column, .descending = descending };
        }

        var limit: ?u64 = null;
        var offset: u64 = 0;
        if (self.cur.kind == .kw_limit) {
            try self.advance();
            const n = try self.expect(.number);
            limit = std.fmt.parseInt(u64, n.text, 10) catch return error.BadNumber;
        }
        if (self.cur.kind == .kw_offset) {
            try self.advance();
            const n = try self.expect(.number);
            offset = std.fmt.parseInt(u64, n.text, 10) catch return error.BadNumber;
        }
        if (self.cur.kind == .semicolon) try self.advance();

        return .{ .select = .{
            .table = table,
            .columns = cols,
            .where_preds = where_preds,
            .order_by = order_by,
            .limit = limit,
            .offset = offset,
        } };
    }

    fn parseUpdate(self: *Parser) ParseError!Stmt {
        _ = try self.expect(.kw_update);
        const table = try self.parseIdent();
        // optional AS alias
        if (self.cur.kind == .kw_as) {
            try self.advance();
            _ = try self.parseIdent();
        } else if (self.cur.kind == .ident) {
            // bare alias only if next is SET... careful: SET is keyword
        }
        _ = try self.expect(.kw_set);

        var sets: std.ArrayList(SetClause) = .empty;
        errdefer {
            for (sets.items) |*s| {
                if (s.column_owned) self.gpa.free(s.column);
                s.value.deinit(self.gpa);
            }
            sets.deinit(self.gpa);
        }
        while (true) {
            const col = try self.parseIdent();
            _ = try self.expect(.eq);
            const val = try self.parseValue();
            if (self.cur.kind == .double_colon) {
                try self.advance();
                if (isTypeKeyword(self.cur.kind) or self.cur.kind == .ident) try self.advance();
            }
            try sets.append(self.gpa, .{ .column = col, .value = val });
            if (self.cur.kind == .comma) {
                try self.advance();
                continue;
            }
            break;
        }

        _ = try self.expect(.kw_where);
        const where_preds = try self.parseWhere();
        if (self.cur.kind == .semicolon) try self.advance();

        return .{ .update = .{
            .table = table,
            .sets = try sets.toOwnedSlice(self.gpa),
            .where_preds = where_preds,
        } };
    }

    fn parseDelete(self: *Parser) ParseError!Stmt {
        _ = try self.expect(.kw_delete);
        _ = try self.expect(.kw_from);
        const table = try self.parseIdent();

        _ = try self.expect(.kw_where);
        const where_preds = try self.parseWhere();
        if (self.cur.kind == .semicolon) try self.advance();

        return .{ .delete = .{
            .table = table,
            .where_preds = where_preds,
        } };
    }
};

fn isTypeKeyword(k: token.TokenKind) bool {
    return switch (k) {
        .kw_int, .kw_integer, .kw_bigint, .kw_smallint, .kw_serial, .kw_bigserial, .kw_text, .kw_varchar, .kw_char, .kw_bool, .kw_boolean, .kw_decimal, .kw_numeric, .kw_timestamp, .kw_timestamptz, .kw_date, .kw_json, .kw_jsonb => true,
        else => false,
    };
}

fn isIdentLike(k: token.TokenKind) bool {
    return switch (k) {
        .ident => true,
        // Keywords usable as identifiers in identifier position.
        .kw_create, .kw_table, .kw_insert, .kw_into, .kw_values, .kw_select, .kw_from, .kw_where, .kw_update, .kw_set, .kw_delete, .kw_primary, .kw_key, .kw_int, .kw_integer, .kw_bigint, .kw_smallint, .kw_serial, .kw_bigserial, .kw_text, .kw_varchar, .kw_char, .kw_bool, .kw_boolean, .kw_decimal, .kw_numeric, .kw_timestamp, .kw_timestamptz, .kw_date, .kw_json, .kw_jsonb, .kw_if, .kw_not, .kw_exists, .kw_null, .kw_default, .kw_unique, .kw_index, .kw_on, .kw_and, .kw_or, .kw_is, .kw_references, .kw_limit, .kw_offset, .kw_order, .kw_by, .kw_asc, .kw_desc, .kw_alter, .kw_add, .kw_column, .kw_begin, .kw_commit, .kw_rollback, .kw_now, .kw_true, .kw_false, .kw_as, .kw_cascade, .kw_restrict, .kw_drop, .kw_check => true,
        else => false,
    };
}



test "parse create insert select" {
    const gpa = std.testing.allocator;
    {
        var p = try Parser.init(gpa, "CREATE TABLE users (id INT PRIMARY KEY, name TEXT);");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt == .create_table);
        try std.testing.expectEqual(@as(usize, 2), stmt.create_table.columns.len);
    }
    {
        var p = try Parser.init(gpa, "INSERT INTO users (id, name) VALUES (1, 'alice');");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt == .insert);
    }
    {
        var p = try Parser.init(gpa, "INSERT INTO users (id, name) VALUES (1, 'alice'), (2, 'bob');");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt == .insert);
        try std.testing.expectEqual(@as(usize, 2), stmt.insert.rows.len);
        try std.testing.expectEqual(@as(usize, 2), stmt.insert.rows[0].len);
    }
    {
        var p = try Parser.init(gpa, "SELECT id, name FROM users WHERE id = 1");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt == .select);
        try std.testing.expectEqual(@as(usize, 1), stmt.select.where_preds.len);
    }
    {
        var p = try Parser.init(gpa, "UPDATE users SET name = 'bob' WHERE id = 1");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt == .update);
    }
    {
        var p = try Parser.init(gpa, "DELETE FROM users WHERE id = 1");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt == .delete);
    }
}

test "parse sub2api-like ddl" {
    const gpa = std.testing.allocator;
    const sql =
        \\CREATE TABLE IF NOT EXISTS settings (
        \\  key VARCHAR(100) PRIMARY KEY,
        \\  value TEXT NOT NULL,
        \\  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        \\);
    ;
    var p = try Parser.init(gpa, sql);
    defer p.deinit();
    var stmt = try p.parseStatement();
    defer freeStmt(gpa, &stmt);
    try std.testing.expect(stmt == .create_table);
    try std.testing.expect(stmt.create_table.if_not_exists);
    try std.testing.expectEqual(@as(usize, 3), stmt.create_table.columns.len);
    try std.testing.expect(stmt.create_table.columns[0].type_tag == .text);
    try std.testing.expect(stmt.create_table.columns[2].default_expr == .now);
}

test "parse where and is null" {
    const gpa = std.testing.allocator;
    var p = try Parser.init(gpa, "SELECT * FROM users WHERE email = 'a@b.c' AND deleted_at IS NULL");
    defer p.deinit();
    var stmt = try p.parseStatement();
    defer freeStmt(gpa, &stmt);
    try std.testing.expectEqual(@as(usize, 2), stmt.select.where_preds.len);
    try std.testing.expect(stmt.select.where_preds[1] == .is_null);
}

test "parse select single-column order by" {
    const gpa = std.testing.allocator;
    var p = try Parser.init(gpa, "SELECT id FROM users WHERE active = true ORDER BY name DESC LIMIT 2 OFFSET 1");
    defer p.deinit();
    var stmt = try p.parseStatement();
    defer freeStmt(gpa, &stmt);
    try std.testing.expect(stmt == .select);
    try std.testing.expect(stmt.select.order_by != null);
    try std.testing.expectEqualStrings("name", stmt.select.order_by.?.column);
    try std.testing.expect(stmt.select.order_by.?.descending);
}

test "parse rejects column-level check constraint" {
    const gpa = std.testing.allocator;
    var p = try Parser.init(gpa, "CREATE TABLE t (id INT PRIMARY KEY CHECK (id > 0))");
    defer p.deinit();
    try std.testing.expectError(error.UnsupportedSyntax, p.parseStatement());
}

test "parse rejects table-level check constraint" {
    const gpa = std.testing.allocator;
    var p = try Parser.init(gpa, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT, CHECK (id > 0))");
    defer p.deinit();
    try std.testing.expectError(error.UnsupportedSyntax, p.parseStatement());
}

test "parse rejects on conflict" {
    const gpa = std.testing.allocator;
    var p = try Parser.init(gpa, "INSERT INTO t VALUES (1) ON CONFLICT DO NOTHING");
    defer p.deinit();
    try std.testing.expectError(error.UnsupportedSyntax, p.parseStatement());
}

test "parse rejects on conflict with conflict target" {
    const gpa = std.testing.allocator;
    var p = try Parser.init(gpa, "INSERT INTO t (id) VALUES (1) ON CONFLICT (id) DO UPDATE SET name = 'x'");
    defer p.deinit();
    try std.testing.expectError(error.UnsupportedSyntax, p.parseStatement());
}

test "parse comparison predicates" {
    const gpa = std.testing.allocator;
    {
        var p = try Parser.init(gpa, "SELECT * FROM t WHERE id != 0");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt.select.where_preds.len == 1);
        try std.testing.expect(stmt.select.where_preds[0] == .cmp);
        try std.testing.expect(stmt.select.where_preds[0].cmp.op == .neq);
    }
    {
        var p = try Parser.init(gpa, "SELECT * FROM t WHERE id < 10");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt.select.where_preds[0] == .cmp);
        try std.testing.expect(stmt.select.where_preds[0].cmp.op == .lt);
    }
    {
        var p = try Parser.init(gpa, "SELECT * FROM t WHERE id > 10");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt.select.where_preds[0] == .cmp);
        try std.testing.expect(stmt.select.where_preds[0].cmp.op == .gt);
    }
    {
        var p = try Parser.init(gpa, "SELECT * FROM t WHERE id <= 10");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt.select.where_preds[0] == .cmp);
        try std.testing.expect(stmt.select.where_preds[0].cmp.op == .lte);
    }
    {
        var p = try Parser.init(gpa, "SELECT * FROM t WHERE id >= 10");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt.select.where_preds[0] == .cmp);
        try std.testing.expect(stmt.select.where_preds[0].cmp.op == .gte);
    }
}

test "parse or group in where clause" {
    const gpa = std.testing.allocator;
    {
        // Single OR group
        var p = try Parser.init(gpa, "SELECT * FROM t WHERE (id = 1 OR id = 2)");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expectEqual(@as(usize, 1), stmt.select.where_preds.len);
        try std.testing.expect(stmt.select.where_preds[0] == .or_group);
        try std.testing.expectEqual(@as(usize, 2), stmt.select.where_preds[0].or_group.groups.len);
    }
    {
        // OR with AND inside each branch
        var p = try Parser.init(gpa, "SELECT * FROM t WHERE (id = 1 AND name = 'a' OR id = 2)");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expect(stmt.select.where_preds[0] == .or_group);
        try std.testing.expectEqual(@as(usize, 2), stmt.select.where_preds[0].or_group.groups.len);
        try std.testing.expectEqual(@as(usize, 2), stmt.select.where_preds[0].or_group.groups[0].len);
    }
    {
        // OR group AND simple predicate
        var p = try Parser.init(gpa, "SELECT * FROM t WHERE (id = 1 OR id = 2) AND active = true");
        defer p.deinit();
        var stmt = try p.parseStatement();
        defer freeStmt(gpa, &stmt);
        try std.testing.expectEqual(@as(usize, 2), stmt.select.where_preds.len);
        try std.testing.expect(stmt.select.where_preds[0] == .or_group);
        try std.testing.expect(stmt.select.where_preds[1] == .eq);
    }
}
