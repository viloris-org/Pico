const std = @import("std");

pub const TokenKind = enum {
    eof,
    ident,
    number,
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
    kw_text,
    kw_bool,
    kw_boolean,
    // symbols
    lparen,
    rparen,
    comma,
    semicolon,
    star,
    eq,
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

        if (isIdentStart(c)) {
            self.pos += 1;
            while (self.pos < self.src.len and isIdentCont(self.src[self.pos])) : (self.pos += 1) {}
            const text = self.src[start..self.pos];
            return .{ .kind = keywordOrIdent(text), .text = text, .start = start };
        }
        if (c >= '0' and c <= '9' or (c == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] >= '0' and self.src[self.pos + 1] <= '9')) {
            if (c == '-') self.pos += 1;
            while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') : (self.pos += 1) {}
            return .{ .kind = .number, .text = self.src[start..self.pos], .start = start };
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

        self.pos += 1;
        const kind: TokenKind = switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            ',' => .comma,
            ';' => .semicolon,
            '*' => .star,
            '=' => .eq,
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
    // Case-insensitive keywords
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
    if (eqlIgnoreCase(text, "TEXT")) return .kw_text;
    if (eqlIgnoreCase(text, "BOOL")) return .kw_bool;
    if (eqlIgnoreCase(text, "BOOLEAN")) return .kw_boolean;
    if (eqlIgnoreCase(text, "TRUE")) return .ident; // handled as bool literal in parser via ident
    if (eqlIgnoreCase(text, "FALSE")) return .ident;
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

/// Unquote SQL string literal including surrounding quotes; unescapes ''.
pub fn unquoteString(gpa: std.mem.Allocator, lit: []const u8) ![]u8 {
    if (lit.len < 2 or lit[0] != '\'' or lit[lit.len - 1] != '\'') return error.BadString;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 1;
    while (i < lit.len - 1) {
        if (lit[i] == '\'' and i + 1 < lit.len - 1 and lit[i + 1] == '\'') {
            try out.append(gpa, '\'');
            i += 2;
        } else {
            try out.append(gpa, lit[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

test "lexer basic" {
    var lex: Lexer = .{ .src = "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)" };
    const kinds = [_]TokenKind{ .kw_create, .kw_table, .ident, .lparen, .ident, .kw_int, .kw_primary, .kw_key, .comma, .ident, .kw_text, .rparen, .eof };
    for (kinds) |want| {
        const t = try lex.next();
        try std.testing.expectEqual(want, t.kind);
    }
}
