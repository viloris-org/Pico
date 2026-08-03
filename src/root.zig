//! RunaDB library root — re-exports subsystem modules.

pub const util = @import("util/bytes.zig");
pub const value = @import("storage/value.zig");
pub const vfs = @import("storage/vfs.zig");
pub const pager = @import("storage/pager.zig");
pub const wal = @import("storage/wal.zig");
pub const table = @import("storage/table.zig");
pub const mvcc = @import("storage/mvcc.zig");
pub const mvcc_test = @import("storage/mvcc_test.zig");
pub const document = @import("storage/document.zig");
pub const graph = @import("storage/graph.zig");
pub const manifest = @import("storage/manifest.zig");
pub const checkpoint = @import("storage/checkpoint.zig");
pub const lsm = struct {
    pub const codec = @import("storage/lsm/codec.zig");
    pub const sstable = @import("storage/lsm/sstable.zig");
    pub const manifest = @import("storage/lsm/manifest.zig");
    pub const store = @import("storage/lsm/store.zig");
};
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
    pub const program = @import("flow/program.zig");
};
pub const server = @import("net/server.zig");
pub const quic = @import("net/quic.zig");
pub const mcp = @import("net/mcp.zig");
pub const connection = @import("net/connection.zig");
pub const registry = @import("net/registry.zig");
pub const runtime = @import("runtime/scheduler.zig");
pub const maintenance = @import("runtime/maintenance.zig");
pub const runtime_test = @import("net/runtime_test.zig");

test {
    _ = util;
    _ = value;
    _ = vfs;
    _ = pager;
    _ = wal;
    _ = table;
    _ = mvcc;
    _ = mvcc_test;
    _ = document;
    _ = graph;
    _ = manifest;
    _ = checkpoint;
    _ = lsm.codec;
    _ = lsm.sstable;
    _ = lsm.manifest;
    _ = lsm.store;
    _ = evidence;
    _ = vector;
    _ = engine;
    _ = txn.transaction;
    _ = txn.tx_test;
    _ = commit.coordinator;
    _ = flow.ast;
    _ = flow.ir;
    _ = flow.exec;
    _ = flow.program;
    _ = server;
    _ = quic;
    _ = mcp;
    _ = connection;
    _ = registry;
    _ = runtime;
    _ = maintenance;
    _ = runtime_test;
}
