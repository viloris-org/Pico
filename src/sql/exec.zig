const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_mod = @import("../storage/engine.zig");
const value = @import("../storage/value.zig");
const parse = @import("parse.zig");
const token = @import("token.zig");
const session_mod = @import("../txn/session.zig");

const exec_core = @import("exec/core.zig");
const exec_insert = @import("exec/insert.zig");
const exec_select = @import("exec/select.zig");
const exec_update = @import("exec/update.zig");
const exec_delete = @import("exec/delete.zig");
const exec_pred = @import("exec/pred.zig");
const Io = std.Io;

pub const Session = exec_core.Session;
pub const ExecError = exec_core.ExecError;
pub const QueryResult = exec_core.QueryResult;
pub const execute = exec_core.execute;
pub const executeScript = exec_core.executeScript;

test "exec create insert select" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    var r1 = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)");
    defer r1.deinit();
    try std.testing.expect(r1 == .empty);

    var r2 = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (1, 'bob')");
    defer r2.deinit();

    var r3 = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 1");
    defer r3.deinit();
    try std.testing.expect(r3 == .rows);
    try std.testing.expectEqual(@as(usize, 1), r3.rows.cells.len);
    try std.testing.expectEqualStrings("bob", r3.rows.cells[0][0].?);

    var r4 = try execute(gpa, &eng, &session, "UPDATE t SET name = 'bobby' WHERE id = 1");
    defer r4.deinit();
    try std.testing.expect(r4 == .empty);

    var r5 = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 1");
    defer r5.deinit();
    try std.testing.expectEqualStrings("bobby", r5.rows.cells[0][0].?);

    var r6 = try execute(gpa, &eng, &session, "DELETE FROM t WHERE id = 1");
    defer r6.deinit();

    var r7 = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 1");
    defer r7.deinit();
    try std.testing.expectEqual(@as(usize, 0), r7.rows.cells.len);

    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
}

test "exec select order by sorts before limit and offset" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-order-by";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, rank INT, name TEXT)");
    defer create.deinit();
    var insert = try execute(gpa, &eng, &session, "INSERT INTO t VALUES (1, 20, 'zoe'), (2, 10, 'amy'), (3, NULL, 'nil'), (4, 30, 'max')");
    defer insert.deinit();

    var asc = try execute(gpa, &eng, &session, "SELECT name FROM t ORDER BY rank ASC LIMIT 2 OFFSET 1");
    defer asc.deinit();
    try std.testing.expectEqual(@as(usize, 2), asc.rows.cells.len);
    try std.testing.expectEqualStrings("zoe", asc.rows.cells[0][0].?);
    try std.testing.expectEqualStrings("max", asc.rows.cells[1][0].?);

    var desc = try execute(gpa, &eng, &session, "SELECT name FROM t ORDER BY rank DESC");
    defer desc.deinit();
    try std.testing.expectEqualStrings("nil", desc.rows.cells[0][0].?);
    try std.testing.expectEqualStrings("max", desc.rows.cells[1][0].?);
}

test "exec multi-row insert is atomic and reports its row count" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-multi-insert";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT UNIQUE)");
    defer create.deinit();

    var inserted = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (1, 'alice'), (2, 'bob')");
    defer inserted.deinit();
    try std.testing.expectEqualStrings("INSERT 0 2", inserted.empty);
    try std.testing.expectEqual(@as(usize, 2), eng.getTable("t").?.rows.items.len);

    try std.testing.expectError(
        error.UniqueViolation,
        execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (3, 'carol'), (4, 'alice')"),
    );
    // The valid first group must not have leaked through before the later error.
    try std.testing.expectEqual(@as(usize, 2), eng.getTable("t").?.rows.items.len);
}

test "exec multi-row insert survives WAL recovery as one batch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-multi-insert-recovery";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var session = Session.init(gpa);
        defer session.deinit();

        var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)");
        defer create.deinit();
        var inserted = try execute(gpa, &eng, &session, "INSERT INTO t VALUES (1, 'alice'), (2, 'bob')");
        defer inserted.deinit();
    }

    {
        var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var session = Session.init(gpa);
        defer session.deinit();
        var rows = try execute(gpa, &eng, &session, "SELECT id, name FROM t");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.rows.cells.len);
    }
}

test "exec comparison operators filter results correctly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-cmp";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, score INT, name TEXT)");
    defer create.deinit();
    var insert = try execute(gpa, &eng, &session, "INSERT INTO t VALUES (1, 10, 'a'), (2, 20, 'b'), (3, 30, 'c'), (4, 40, 'd')");
    defer insert.deinit();

    // !=
    { var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE id != 2 ORDER BY id");
      defer res.deinit();
      try std.testing.expectEqual(@as(usize, 3), res.rows.cells.len);
      try std.testing.expectEqualStrings("1", res.rows.cells[0][0].?);
      try std.testing.expectEqualStrings("3", res.rows.cells[1][0].?);
      try std.testing.expectEqualStrings("4", res.rows.cells[2][0].?);
    }
    // <
    { var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE score < 30 ORDER BY id");
      defer res.deinit();
      try std.testing.expectEqual(@as(usize, 2), res.rows.cells.len);
    }
    // >
    { var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE score > 20 ORDER BY id");
      defer res.deinit();
      try std.testing.expectEqual(@as(usize, 2), res.rows.cells.len);
      try std.testing.expectEqualStrings("3", res.rows.cells[0][0].?);
    }
    // <=
    { var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE score <= 20 ORDER BY id");
      defer res.deinit();
      try std.testing.expectEqual(@as(usize, 2), res.rows.cells.len);
    }
    // >=
    { var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE score >= 30 ORDER BY id");
      defer res.deinit();
      try std.testing.expectEqual(@as(usize, 2), res.rows.cells.len);
      try std.testing.expectEqualStrings("3", res.rows.cells[0][0].?);
    }
    // text comparison
    { var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE name > 'b' ORDER BY id");
      defer res.deinit();
      try std.testing.expectEqual(@as(usize, 2), res.rows.cells.len);
      try std.testing.expectEqualStrings("3", res.rows.cells[0][0].?);
    }
    // <> operator (SQL-standard not-equal)
    { var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE id <> 2 ORDER BY id");
      defer res.deinit();
      try std.testing.expectEqual(@as(usize, 3), res.rows.cells.len);
      try std.testing.expectEqualStrings("1", res.rows.cells[0][0].?);
    }
}

test "exec in and like predicates filter rows" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-in-like";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)");
    defer create.deinit();
    var insert = try execute(gpa, &eng, &session, "INSERT INTO t VALUES (1, 'alice'), (2, 'al_ice'), (3, 'bob'), (4, NULL)");
    defer insert.deinit();

    {
        var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE id IN (1, 3) ORDER BY id");
        defer res.deinit();
        try std.testing.expectEqual(@as(usize, 2), res.rows.cells.len);
        try std.testing.expectEqualStrings("1", res.rows.cells[0][0].?);
        try std.testing.expectEqualStrings("3", res.rows.cells[1][0].?);
    }
    {
        var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE id NOT IN (1, 3, NULL) ORDER BY id");
        defer res.deinit();
        // A NULL list item yields unknown for otherwise unmatched rows.
        try std.testing.expectEqual(@as(usize, 0), res.rows.cells.len);
    }
    {
        var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE name LIKE 'a%' ORDER BY id");
        defer res.deinit();
        try std.testing.expectEqual(@as(usize, 2), res.rows.cells.len);
        try std.testing.expectEqualStrings("1", res.rows.cells[0][0].?);
        try std.testing.expectEqualStrings("2", res.rows.cells[1][0].?);
    }
    {
        var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE name LIKE 'al\\_%'");
        defer res.deinit();
        try std.testing.expectEqual(@as(usize, 1), res.rows.cells.len);
        try std.testing.expectEqualStrings("2", res.rows.cells[0][0].?);
    }
    {
        var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE NOT name LIKE 'a%' ORDER BY id");
        defer res.deinit();
        try std.testing.expectEqual(@as(usize, 1), res.rows.cells.len);
        try std.testing.expectEqualStrings("3", res.rows.cells[0][0].?);
    }
}

test "exec or_group in where clause" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-or";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, score INT, name TEXT)");
    defer create.deinit();
    var insert = try execute(gpa, &eng, &session, "INSERT INTO t VALUES (1, 10, 'a'), (2, 20, 'b'), (3, 30, 'c'), (4, 40, 'd')");
    defer insert.deinit();

    // OR: match either condition
    { var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE (id = 1 OR id = 3) ORDER BY id");
      defer res.deinit();
      try std.testing.expectEqual(@as(usize, 2), res.rows.cells.len);
      try std.testing.expectEqualStrings("1", res.rows.cells[0][0].?);
      try std.testing.expectEqualStrings("3", res.rows.cells[1][0].?);
    }
    // OR group AND another predicate
    { var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE (id = 2 OR id = 3) AND score >= 20 ORDER BY id");
      defer res.deinit();
      try std.testing.expectEqual(@as(usize, 2), res.rows.cells.len);
    }
    // OR with AND groups
    { var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE (id = 1 AND name = 'a' OR id = 4) ORDER BY id");
      defer res.deinit();
      try std.testing.expectEqual(@as(usize, 2), res.rows.cells.len);
      try std.testing.expectEqualStrings("1", res.rows.cells[0][0].?);
    }
    // OR returns empty when no match
    { var res = try execute(gpa, &eng, &session, "SELECT id FROM t WHERE (id = 99 OR id = 100) ORDER BY id");
      defer res.deinit();
      try std.testing.expectEqual(@as(usize, 0), res.rows.cells.len);
    }
}

test "exec sub2api-shaped settings and users" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-sub2api";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    const ddl =
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\  filename TEXT PRIMARY KEY,
        \\  checksum TEXT NOT NULL,
        \\  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        \\);
        \\CREATE TABLE IF NOT EXISTS settings (
        \\  key VARCHAR(100) PRIMARY KEY,
        \\  value TEXT NOT NULL,
        \\  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        \\);
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id BIGSERIAL PRIMARY KEY,
        \\  email VARCHAR(255) NOT NULL UNIQUE,
        \\  password_hash VARCHAR(255) NOT NULL,
        \\  role VARCHAR(20) NOT NULL DEFAULT 'user',
        \\  balance DECIMAL(20, 8) NOT NULL DEFAULT 0,
        \\  status VARCHAR(20) NOT NULL DEFAULT 'active',
        \\  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        \\  deleted_at TIMESTAMPTZ
        \\);
    ;

    const results = try executeScript(gpa, &eng, &session, ddl);
    defer {
        for (results) |*r| r.deinit();
        gpa.free(results);
    }

    var r1 = try execute(gpa, &eng, &session, "INSERT INTO schema_migrations (filename, checksum) VALUES ('001_init.sql', 'abc')");
    defer r1.deinit();

    var r2 = try execute(gpa, &eng, &session, "INSERT INTO settings (key, value) VALUES ('site_name', 'Sub2API')");
    defer r2.deinit();

    var r3 = try execute(gpa, &eng, &session, "SELECT value FROM settings WHERE key = 'site_name'");
    defer r3.deinit();
    try std.testing.expectEqualStrings("Sub2API", r3.rows.cells[0][0].?);

    var r4 = try execute(gpa, &eng, &session, "INSERT INTO users (email, password_hash) VALUES ('admin@example.com', 'hash')");
    defer r4.deinit();

    var r5 = try execute(gpa, &eng, &session, "SELECT id, email, role, balance FROM users WHERE email = 'admin@example.com' AND deleted_at IS NULL");
    defer r5.deinit();
    try std.testing.expectEqual(@as(usize, 1), r5.rows.cells.len);
    try std.testing.expectEqualStrings("1", r5.rows.cells[0][0].?);
    try std.testing.expectEqualStrings("admin@example.com", r5.rows.cells[0][1].?);
    try std.testing.expectEqualStrings("user", r5.rows.cells[0][2].?);
    try std.testing.expectEqualStrings("0", r5.rows.cells[0][3].?);

    var r6 = try execute(gpa, &eng, &session, "UPDATE users SET status = 'disabled' WHERE email = 'admin@example.com'");
    defer r6.deinit();

    var r7 = try execute(gpa, &eng, &session, "SELECT status FROM users WHERE id = 1");
    defer r7.deinit();
    try std.testing.expectEqualStrings("disabled", r7.rows.cells[0][0].?);

    // IF NOT EXISTS second time
    var r8 = try execute(gpa, &eng, &session, "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)");
    defer r8.deinit();

    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
}

test "exec rejects syntax whose semantics are not implemented" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-rejections";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    try std.testing.expectError(error.UnsupportedSyntax, execute(gpa, &eng, &session, "CREATE INDEX idx_t_id ON t(id)"));
    try std.testing.expectError(error.UnsupportedSyntax, execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, parent_id INT REFERENCES parent(id))"));

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)");
    defer create.deinit();
    try std.testing.expectError(error.UnsupportedSyntax, execute(gpa, &eng, &session, "INSERT INTO t VALUES (1, 'alice') RETURNING id"));
    try std.testing.expectError(error.UnsupportedSyntax, execute(gpa, &eng, &session, "SELECT * FROM t ORDER BY id, name"));
    try std.testing.expectError(error.UnsupportedSyntax, execute(gpa, &eng, &session, "CREATE TABLE t2 (id INT PRIMARY KEY CHECK (id > 0))"));
    try std.testing.expectError(error.UnsupportedSyntax, execute(gpa, &eng, &session, "CREATE TABLE t3 (id INT PRIMARY KEY, name TEXT, CHECK (id > 0))"));
    try std.testing.expectError(error.UnsupportedSyntax, execute(gpa, &eng, &session, "INSERT INTO t VALUES (1) ON CONFLICT DO NOTHING"));
    try std.testing.expectError(error.UnsupportedSyntax, execute(gpa, &eng, &session, "INSERT INTO t (id) VALUES (1) ON CONFLICT (id) DO UPDATE SET name = 'x'"));
}

test "alter table changes survive WAL recovery" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-alter-recovery";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var session = Session.init(gpa);
        defer session.deinit();
        var create = try execute(gpa, &eng, &session, "CREATE TABLE accounts (id INT PRIMARY KEY, name TEXT)");
        defer create.deinit();
        var insert = try execute(gpa, &eng, &session, "INSERT INTO accounts VALUES (1, 'alice')");
        defer insert.deinit();
        var add = try execute(gpa, &eng, &session, "ALTER TABLE accounts ADD COLUMN active BOOLEAN NOT NULL DEFAULT true");
        defer add.deinit();
        var set_default = try execute(gpa, &eng, &session, "ALTER TABLE accounts ALTER COLUMN name SET DEFAULT 'anonymous'");
        defer set_default.deinit();
        var set_null = try execute(gpa, &eng, &session, "ALTER TABLE accounts ALTER COLUMN name SET NOT NULL");
        defer set_null.deinit();
        var clear_default = try execute(gpa, &eng, &session, "ALTER TABLE accounts ALTER COLUMN name DROP DEFAULT");
        defer clear_default.deinit();
        var clear_null = try execute(gpa, &eng, &session, "ALTER TABLE accounts ALTER COLUMN name DROP NOT NULL");
        defer clear_null.deinit();
        var drop = try execute(gpa, &eng, &session, "ALTER TABLE accounts DROP COLUMN name");
        defer drop.deinit();
    }
    {
        var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var session = Session.init(gpa);
        defer session.deinit();
        var result = try execute(gpa, &eng, &session, "SELECT active FROM accounts WHERE id = 1");
        defer result.deinit();
        try std.testing.expectEqualStrings("t", result.rows.cells[0][0].?);
        const active = eng.getTable("accounts").?.columns[1];
        try std.testing.expect(active.not_null);
        try std.testing.expect(active.default_expr == .literal);
    }
}

test "exec begin commit publishes write set; rollback discards" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-txn";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)");
    defer create.deinit();

    var begin1 = try execute(gpa, &eng, &session, "BEGIN");
    defer begin1.deinit();
    try std.testing.expectEqualStrings("BEGIN", begin1.empty);
    try std.testing.expect(session.state == .active);

    var ins = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (1, 'alice')");
    defer ins.deinit();

    // Private write set: published table empty, SELECT in txn sees the row.
    try std.testing.expectEqual(@as(usize, 0), eng.getTable("t").?.rows.items.len);
    var sel_tx = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 1");
    defer sel_tx.deinit();
    try std.testing.expectEqualStrings("alice", sel_tx.rows.cells[0][0].?);

    var commit = try execute(gpa, &eng, &session, "COMMIT");
    defer commit.deinit();
    try std.testing.expect(session.state == .idle);
    try std.testing.expectEqual(@as(usize, 1), eng.getTable("t").?.rows.items.len);

    var begin2 = try execute(gpa, &eng, &session, "BEGIN");
    defer begin2.deinit();
    var ins2 = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (2, 'bob')");
    defer ins2.deinit();
    var rb = try execute(gpa, &eng, &session, "ROLLBACK");
    defer rb.deinit();
    try std.testing.expectEqual(@as(usize, 1), eng.getTable("t").?.rows.items.len);

    var sel = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 2");
    defer sel.deinit();
    try std.testing.expectEqual(@as(usize, 0), sel.rows.cells.len);
}

test "exec statement error fails transaction until rollback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-txn-failed";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
    defer eng.deinit();
    var session = Session.init(gpa);
    defer session.deinit();

    var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT NOT NULL)");
    defer create.deinit();
    var begin = try execute(gpa, &eng, &session, "BEGIN");
    defer begin.deinit();
    var ins = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (1, 'ok')");
    defer ins.deinit();

    try std.testing.expectError(error.NotNullViolation, execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (2, NULL)"));
    try std.testing.expect(session.state == .failed);
    try std.testing.expectError(error.InFailedTransaction, execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 1"));
    try std.testing.expectError(error.InFailedTransaction, execute(gpa, &eng, &session, "COMMIT"));

    var rb = try execute(gpa, &eng, &session, "ROLLBACK");
    defer rb.deinit();
    try std.testing.expect(session.state == .idle);
    try std.testing.expectEqual(@as(usize, 0), eng.getTable("t").?.rows.items.len);
}

test "exec committed transaction survives WAL recovery; rolled back does not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-exec-txn-recovery";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var session = Session.init(gpa);
        defer session.deinit();

        var create = try execute(gpa, &eng, &session, "CREATE TABLE t (id INT PRIMARY KEY, name TEXT)");
        defer create.deinit();

        var begin_c = try execute(gpa, &eng, &session, "BEGIN");
        defer begin_c.deinit();
        var insert_c = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (1, 'committed')");
        defer insert_c.deinit();
        var commit_c = try execute(gpa, &eng, &session, "COMMIT");
        defer commit_c.deinit();

        var begin_r = try execute(gpa, &eng, &session, "BEGIN");
        defer begin_r.deinit();
        var insert_r = try execute(gpa, &eng, &session, "INSERT INTO t (id, name) VALUES (2, 'rolled')");
        defer insert_r.deinit();
        // Crash-equivalent: drop the engine without COMMIT. Write set never entered WAL.
    }

    {
        var eng = try engine_mod.Engine.open(gpa, io, dir_name, false);
        defer eng.deinit();
        var session = Session.init(gpa);
        defer session.deinit();
        var all = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 1");
        defer all.deinit();
        try std.testing.expectEqualStrings("committed", all.rows.cells[0][0].?);
        var ghost = try execute(gpa, &eng, &session, "SELECT name FROM t WHERE id = 2");
        defer ghost.deinit();
        try std.testing.expectEqual(@as(usize, 0), ghost.rows.cells.len);
    }
}
