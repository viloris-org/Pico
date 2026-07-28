//! Pico library root — re-exports subsystem modules.

pub const util = @import("util/bytes.zig");
pub const value = @import("storage/value.zig");
pub const vfs = @import("storage/vfs.zig");
pub const pager = @import("storage/pager.zig");
pub const wal = @import("storage/wal.zig");
pub const table = @import("storage/table.zig");
pub const engine = @import("storage/engine.zig");
pub const txn = struct {
    pub const session = @import("txn/session.zig");
};
pub const sql = struct {
    pub const token = @import("sql/token.zig");
    pub const parse = @import("sql/parse.zig");
    pub const exec = @import("sql/exec.zig");
};
pub const pg = @import("net/pg.zig");
pub const server = @import("net/server.zig");

test {
    _ = util;
    _ = value;
    _ = vfs;
    _ = pager;
    _ = wal;
    _ = table;
    _ = engine;
    _ = txn.session;
    _ = sql.token;
    _ = sql.parse;
    _ = sql.exec;
    _ = pg;
    _ = server;
}
