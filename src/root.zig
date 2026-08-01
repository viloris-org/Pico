//! RunaDB library root — re-exports subsystem modules.

pub const util = @import("util/bytes.zig");
pub const value = @import("storage/value.zig");
pub const vfs = @import("storage/vfs.zig");
pub const pager = @import("storage/pager.zig");
pub const wal = @import("storage/wal.zig");
pub const table = @import("storage/table.zig");
pub const checkpoint = @import("storage/checkpoint.zig");
pub const evidence = @import("storage/evidence.zig");
pub const vector = @import("vector.zig");
pub const engine = @import("storage/engine.zig");
pub const txn = struct {
    pub const transaction = @import("txn/transaction.zig");
    pub const tx_test = @import("txn/tx_test.zig");
};
pub const commit = struct {
    pub const coordinator = @import("commit/coordinator.zig");
};
pub const flow = struct {
    pub const ast = @import("flow/ast.zig");
    pub const ir = @import("flow/ir.zig");
    pub const exec = @import("flow/exec.zig");
};
pub const server = @import("net/server.zig");
pub const mcp = @import("net/mcp.zig");

test {
    _ = util;
    _ = value;
    _ = vfs;
    _ = pager;
    _ = wal;
    _ = table;
    _ = checkpoint;
    _ = evidence;
    _ = vector;
    _ = engine;
    _ = txn.transaction;
    _ = txn.tx_test;
    _ = commit.coordinator;
    _ = flow.ast;
    _ = flow.ir;
    _ = flow.exec;
    _ = server;
    _ = mcp;
}
