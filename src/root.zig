//! RunaDB library root — re-exports subsystem modules.

pub const util = @import("util/bytes.zig");
pub const value = @import("storage/value.zig");
pub const vfs = @import("storage/vfs.zig");
pub const pager = @import("storage/pager.zig");
pub const wal = @import("storage/wal.zig");
pub const table = @import("storage/table.zig");
pub const checkpoint = @import("storage/checkpoint.zig");
pub const evidence = @import("storage/evidence.zig");
pub const engine = @import("storage/engine.zig");
pub const flow = struct {
    pub const ast = @import("flow/ast.zig");
    pub const ir = @import("flow/ir.zig");
    pub const exec = @import("flow/exec.zig");
};
pub const server = @import("net/server.zig");

test {
    _ = util;
    _ = value;
    _ = vfs;
    _ = pager;
    _ = wal;
    _ = table;
    _ = checkpoint;
    _ = evidence;
    _ = engine;
    _ = flow.ast;
    _ = flow.ir;
    _ = flow.exec;
    _ = server;
}
