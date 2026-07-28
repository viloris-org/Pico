const std = @import("std");

pub const TokenKind = enum {
    eof,
    ident,
    number,
    /// Decimal / scientific numeric literal stored as text (for DECIMAL/NUMERIC).
    float,
    string,
    // keywords
    kw_create,
    kw_table,
    kw_insert,
    kw_into,
    kw_values,
    kw_select,
    kw_from,
    kw_where,
    kw_update,
    kw_set,
    kw_delete,
    kw_primary,
    kw_key,
    kw_int,
    kw_integer,
    kw_bigint,
    kw_smallint,
    kw_serial,
    kw_bigserial,
    kw_text,
    kw_varchar,
    kw_char,
    kw_bool,
    kw_boolean,
    kw_decimal,
    kw_numeric,
    kw_timestamp,
    kw_timestamptz,
    kw_date,
    kw_json,
    kw_jsonb,
    kw_if,
    kw_not,
    kw_exists,
    kw_null,
    kw_default,
    kw_unique,
    kw_index,
    kw_on,
    kw_and,
    kw_or,
    kw_is,
    kw_references,
    kw_limit,
    kw_offset,
    kw_order,
    kw_by,
    kw_asc,
    kw_desc,
    kw_alter,
    kw_add,
    kw_column,
    kw_begin,
    kw_commit,
    kw_rollback,
    kw_now,
    kw_true,
    kw_false,
    kw_as,
    kw_cascade,
    kw_restrict,
    kw_drop,
    kw_check,
    // symbols
    lparen,
    rparen,
    lbracket,
    rbracket,
    comma,
    semicolon,
    star,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    double_colon,
};

pub const Token = struct {
    kind: TokenKind,
    /// Slice into original SQL text.
    text: []const u8,
    start: usize,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn next(self: *Lexer) !Token {
        self.skipWs();
        if (self.pos >= self.src.len) {
            return .{ .kind = .eof, .text = self.src[self.pos..self.pos], .start = self.pos };
        }
        const start = self.pos;
        const c = self.src[self.pos];

        // Double-quoted identifier
        if (c == '"') {
            self.pos += 1;
            while (self.pos < self.src.len) {
                if (self.src[self.pos] == '"') {
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '"') {
                        self.pos += 2;
                        continue;
                    }
                    self.pos += 1;
                    return .{ .kind = .ident, .text = self.src[start..self.pos], .start = start };
                }
                self.pos += 1;
            }
            return error.UnterminatedString;
        }

        if (isIdentStart(c)) {
            self.pos += 1;
            while (self.pos < self.src.len and isIdentCont(self.src[self.pos])) : (self.pos += 1) {}
            const text = self.src[start..self.pos];
            return .{ .kind = keywordOrIdent(text), .text = text, .start = start };
        }

        // Numbers: integer or float (optional leading -)
        if (c >= '0' and c <= '9' or (c == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] >= '0' and self.src[self.pos + 1] <= '9')) {
            if (c == '-') self.pos += 1;
            while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') : (self.pos += 1) {}
            var is_float = false;
            if (self.pos < self.src.len and self.src[self.pos] == '.') {
                const after = self.pos + 1;
                if (after < self.src.len and self.src[after] >= '0' and self.src[after] <= '9') {
                    is_float = true;
                    self.pos = after;
                    while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') : (self.pos += 1) {}
                }
            }
            return .{
                .kind = if (is_float) .float else .number,
                .text = self.src[start..self.pos],
                .start = start,
            };
        }

        if (c == '\'') {
            self.pos += 1;
            while (self.pos < self.src.len) {
                if (self.src[self.pos] == '\'') {
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
                        self.pos += 2; // escaped ''
                        continue;
                    }
                    self.pos += 1;
                    return .{ .kind = .string, .text = self.src[start..self.pos], .start = start };
                }
                self.pos += 1;
            }
            return error.UnterminatedString;
        }

        // Multi-char operators
        if (c == ':' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == ':') {
            self.pos += 2;
            return .{ .kind = .double_colon, .text = self.src[start..self.pos], .start = start };
        }
        if (c == '!' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            self.pos += 2;
            return .{ .kind = .neq, .text = self.src[start..self.pos], .start = start };
        }
        if (c == '<' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
            self.pos += 2;
            return .{ .kind = .neq, .text = self.src[start..self.pos], .start = start };
        }
        if (c == '<' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            self.pos += 2;
            return .{ .kind = .lte, .text = self.src[start..self.pos], .start = start };
        }
        if (c == '>' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            self.pos += 2;
            return .{ .kind = .gte, .text = self.src[start..self.pos], .start = start };
        }

        self.pos += 1;
        const kind: TokenKind = switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            ',' => .comma,
            ';' => .semicolon,
            '*' => .star,
            '=' => .eq,
            '<' => .lt,
            '>' => .gt,
            else => return error.UnexpectedChar,
        };
        return .{ .kind = kind, .text = self.src[start..self.pos], .start = start };
    }

    fn skipWs(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
                continue;
            }
            // -- line comment
            if (c == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '-') {
                self.pos += 2;
                while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
                continue;
            }
            // /* block comment */
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                self.pos += 2;
                while (self.pos + 1 < self.src.len) {
                    if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                        self.pos += 2;
                        break;
                    }
                    self.pos += 1;
                }
                continue;
            }
            break;
        }
    }
};

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn keywordOrIdent(text: []const u8) TokenKind {
    if (eqlIgnoreCase(text, "CREATE")) return .kw_create;
    if (eqlIgnoreCase(text, "TABLE")) return .kw_table;
    if (eqlIgnoreCase(text, "INSERT")) return .kw_insert;
    if (eqlIgnoreCase(text, "INTO")) return .kw_into;
    if (eqlIgnoreCase(text, "VALUES")) return .kw_values;
    if (eqlIgnoreCase(text, "SELECT")) return .kw_select;
    if (eqlIgnoreCase(text, "FROM")) return .kw_from;
    if (eqlIgnoreCase(text, "WHERE")) return .kw_where;
    if (eqlIgnoreCase(text, "UPDATE")) return .kw_update;
    if (eqlIgnoreCase(text, "SET")) return .kw_set;
    if (eqlIgnoreCase(text, "DELETE")) return .kw_delete;
    if (eqlIgnoreCase(text, "PRIMARY")) return .kw_primary;
    if (eqlIgnoreCase(text, "KEY")) return .kw_key;
    if (eqlIgnoreCase(text, "INT")) return .kw_int;
    if (eqlIgnoreCase(text, "INTEGER")) return .kw_integer;
    if (eqlIgnoreCase(text, "BIGINT")) return .kw_bigint;
    if (eqlIgnoreCase(text, "SMALLINT")) return .kw_smallint;
    if (eqlIgnoreCase(text, "SERIAL")) return .kw_serial;
    if (eqlIgnoreCase(text, "BIGSERIAL")) return .kw_bigserial;
    if (eqlIgnoreCase(text, "TEXT")) return .kw_text;
    if (eqlIgnoreCase(text, "VARCHAR")) return .kw_varchar;
    if (eqlIgnoreCase(text, "CHAR")) return .kw_char;
    if (eqlIgnoreCase(text, "CHARACTER")) return .kw_char;
    if (eqlIgnoreCase(text, "BOOL")) return .kw_bool;
    if (eqlIgnoreCase(text, "BOOLEAN")) return .kw_boolean;
    if (eqlIgnoreCase(text, "DECIMAL")) return .kw_decimal;
    if (eqlIgnoreCase(text, "NUMERIC")) return .kw_numeric;
    if (eqlIgnoreCase(text, "TIMESTAMP")) return .kw_timestamp;
    if (eqlIgnoreCase(text, "TIMESTAMPTZ")) return .kw_timestamptz;
    if (eqlIgnoreCase(text, "DATE")) return .kw_date;
    if (eqlIgnoreCase(text, "JSON")) return .kw_json;
    if (eqlIgnoreCase(text, "JSONB")) return .kw_jsonb;
    if (eqlIgnoreCase(text, "IF")) return .kw_if;
    if (eqlIgnoreCase(text, "NOT")) return .kw_not;
    if (eqlIgnoreCase(text, "EXISTS")) return .kw_exists;
    if (eqlIgnoreCase(text, "NULL")) return .kw_null;
    if (eqlIgnoreCase(text, "DEFAULT")) return .kw_default;
    if (eqlIgnoreCase(text, "UNIQUE")) return .kw_unique;
    if (eqlIgnoreCase(text, "INDEX")) return .kw_index;
    if (eqlIgnoreCase(text, "ON")) return .kw_on;
    if (eqlIgnoreCase(text, "AND")) return .kw_and;
    if (eqlIgnoreCase(text, "OR")) return .kw_or;
    if (eqlIgnoreCase(text, "IS")) return .kw_is;
    if (eqlIgnoreCase(text, "REFERENCES")) return .kw_references;
    if (eqlIgnoreCase(text, "LIMIT")) return .kw_limit;
    if (eqlIgnoreCase(text, "OFFSET")) return .kw_offset;
    if (eqlIgnoreCase(text, "ORDER")) return .kw_order;
    if (eqlIgnoreCase(text, "BY")) return .kw_by;
    if (eqlIgnoreCase(text, "ASC")) return .kw_asc;
    if (eqlIgnoreCase(text, "DESC")) return .kw_desc;
    if (eqlIgnoreCase(text, "ALTER")) return .kw_alter;
    if (eqlIgnoreCase(text, "ADD")) return .kw_add;
    if (eqlIgnoreCase(text, "COLUMN")) return .kw_column;
    if (eqlIgnoreCase(text, "BEGIN")) return .kw_begin;
    if (eqlIgnoreCase(text, "COMMIT")) return .kw_commit;
    if (eqlIgnoreCase(text, "ROLLBACK")) return .kw_rollback;
    if (eqlIgnoreCase(text, "NOW")) return .kw_now;
    if (eqlIgnoreCase(text, "TRUE")) return .kw_true;
    if (eqlIgnoreCase(text, "FALSE")) return .kw_false;
    if (eqlIgnoreCase(text, "AS")) return .kw_as;
    if (eqlIgnoreCase(text, "CASCADE")) return .kw_cascade;
    if (eqlIgnoreCase(text, "RESTRICT")) return .kw_restrict;
    if (eqlIgnoreCase(text, "DROP")) return .kw_drop;
    if (eqlIgnoreCase(text, "CHECK")) return .kw_check;
    return .ident;
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

/// Unquote SQL string or double-quoted identifier; unescapes '' / "".
pub fn unquoteString(gpa: std.mem.Allocator, lit: []const u8) ![]u8 {
    if (lit.len < 2) return error.BadString;
    const q = lit[0];
    if ((q != '\'' and q != '"') or lit[lit.len - 1] != q) return error.BadString;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 1;
    while (i < lit.len - 1) {
        if (lit[i] == q and i + 1 < lit.len - 1 and lit[i + 1] == q) {
            try out.append(gpa, q);
            i += 2;
        } else {
            try out.append(gpa, lit[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Identifier text without quotes (borrows for bare idents; allocates for quoted).
pub fn identText(gpa: std.mem.Allocator, tok: Token) !struct { text: []const u8, owned: bool } {
    if (tok.text.len >= 2 and tok.text[0] == '"') {
        const s = try unquoteString(gpa, tok.text);
        return .{ .text = s, .owned = true };
    }
    return .{ .text = tok.text, .owned = false };
}

test "lexer basic" {
    var lex: Lexer = .{ .src = "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)" };
    const kinds = [_]TokenKind{ .kw_create, .kw_table, .ident, .lparen, .ident, .kw_int, .kw_primary, .kw_key, .comma, .ident, .kw_text, .rparen, .eof };
    for (kinds) |want| {
        const t = try lex.next();
        try std.testing.expectEqual(want, t.kind);
    }
}

test "lexer pg types and float" {
    var lex: Lexer = .{ .src = "BIGSERIAL VARCHAR(100) 1.5 TIMESTAMPTZ JSONB" };
    try std.testing.expectEqual(TokenKind.kw_bigserial, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.kw_varchar, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.lparen, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.number, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.rparen, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.float, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.kw_timestamptz, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.kw_jsonb, (try lex.next()).kind);
}
