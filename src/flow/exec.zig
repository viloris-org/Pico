//! Bind and execute the initial read-only Runa Flow relation slice.
//!
//! Execution is backed by the streaming execution program (`program.zig`,
//! roadmap Phase 6): the materialized entry points below drain the program,
//! so the validated Runa Query IR execution paths and the protocol layer's
//! streaming path share one scan implementation by construction.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const ir = @import("ir.zig");
const engine_mod = @import("../storage/engine.zig");
const document_mod = @import("../storage/document.zig");
const value = @import("../storage/value.zig");
const txn_mod = @import("../txn/transaction.zig");
const program = @import("program.zig");

pub const ProgramError = program.ProgramError;
/// Cooperative cancellation probe (roadmap Phase 6). The caller — a RunaDB
/// Connection — owns the state and the statement generation that a
/// `CANCEL_REQUEST` marks; the flow module only calls `check` between bounded
/// work units during scan execution and never stores the probe past the call.
/// A null probe disables cancellation, preserving the engine-level and MCP call
/// paths unchanged.
pub const CancelProbe = program.CancelProbe;
/// Per-execution options. The default options carry no cancellation probe.
pub const ExecOptions = program.ExecOptions;
/// Streaming execution program: one execution instance of a bound Request
/// that produces bounded result batches (see `program.zig`).
pub const Program = program.Program;
pub const Batch = program.Batch;
pub const BatchLimit = program.BatchLimit;

pub const ExecError = ProgramError;

pub const Result = struct {
    columns: [][]const u8,
    cells: [][]?[]const u8,
    owned_text: std.ArrayList([]u8),
    gpa: Allocator,

    pub fn deinit(self: *Result) void {
        self.gpa.free(self.columns);
        for (self.cells) |row| self.gpa.free(row);
        self.gpa.free(self.cells);
        for (self.owned_text.items) |text| self.gpa.free(text);
        self.owned_text.deinit(self.gpa);
    }
};

pub fn compile(gpa: Allocator, source: []const u8) !ir.Request {
    var parsed = try ast.parse(gpa, source);
    defer parsed.deinit(gpa);
    return ir.bind(gpa, parsed);
}

pub fn execute(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request) ExecError!Result {
    return executeOpts(gpa, eng, request, .{});
}

/// Execute a Request with optional cooperative cancellation: the scan loops
/// check `opts.cancel` between bounded work units, so a Connection's
/// `CANCEL_REQUEST` mark stops a long scan at the next row boundary. The plain
/// `execute` entry point passes the default options and never observes
/// cancellation. Execution drains the streaming program, so the materialized
/// result is byte-identical to streaming the same program to the wire.
pub fn executeOpts(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, opts: ExecOptions) ExecError!Result {
    var prog = try program.open(gpa, eng, request, opts);
    defer prog.deinit();
    return drain(gpa, &prog);
}

/// Execute a Request through an explicit transaction with Read Committed
/// visibility (read-your-writes). Drains the transaction-scoped program.
pub fn executeTx(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, tx: *txn_mod.Transaction) ExecError!Result {
    return executeTxOpts(gpa, eng, request, tx, .{});
}

/// Transaction-scoped execution with the same optional cancellation probe as
/// `executeOpts`.
pub fn executeTxOpts(gpa: Allocator, eng: *engine_mod.Engine, request: *const ir.Request, tx: *txn_mod.Transaction, opts: ExecOptions) ExecError!Result {
    var prog = try program.openTx(gpa, eng, request, tx, opts);
    defer prog.deinit();
    return drain(gpa, &prog);
}

/// Streaming entry point (roadmap Phase 6): open an execution program under
/// the engine's statement-execution lock, then produce bounded batches with
/// `Program.nextBatch` after the lock is released. Errors during opening map
/// to the same codes as the materialized path.
pub const openProgram = program.open;
pub const openProgramTx = program.openTx;

/// Drain a program into a fully materialized `Result`. Each bounded batch is
/// released and its rows and text moved into the result, so the drain is
/// exactly the stream's concatenation; `prog.takeColumns` transfers the owned
/// column metadata.
fn drain(gpa: Allocator, prog: *Program) ExecError!Result {
    var cells: std.ArrayList([]?[]const u8) = .empty;
    errdefer {
        for (cells.items) |row| gpa.free(row);
        cells.deinit(gpa);
    }
    var owned_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_text.items) |text| gpa.free(text);
        owned_text.deinit(gpa);
    }

    var batch: Batch = .{ .gpa = gpa };
    defer batch.deinit();
    while (true) {
        try prog.nextBatch(&batch, .{ .max_rows = std.math.maxInt(usize), .max_bytes = std.math.maxInt(u64) });
        var parts = batch.release();
        // Move the parts' items into the accumulating lists. On error before
        // the move completes, `parts.deinit` frees everything it still owns;
        // after the move, only the parts' containers are freed (the items now
        // belong to cells/owned_text).
        errdefer parts.deinit(gpa);
        try cells.ensureUnusedCapacity(gpa, parts.rows.items.len);
        try owned_text.ensureUnusedCapacity(gpa, parts.owned_text.items.len);
        for (parts.rows.items) |row| cells.appendAssumeCapacity(row);
        for (parts.owned_text.items) |text| owned_text.appendAssumeCapacity(text);
        var moved_rows = parts.rows;
        var moved_text = parts.owned_text;
        moved_rows.deinit(gpa);
        moved_text.deinit(gpa);
        if (batch.done) break;
    }

    var columns = prog.takeColumns();
    // Column names and cell text share one owned list (the Result shape):
    // move the transferred column names into the result's owned text.
    try owned_text.appendSlice(gpa, columns.column_text.items);
    columns.column_text.deinit(gpa);
    return .{
        .columns = columns.columns,
        .cells = try cells.toOwnedSlice(gpa),
        .owned_text = owned_text,
        .gpa = gpa,
    };
}

test "executes a read-only relation flow" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-exec";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try std.testing.allocator.dupe(u8, "name"), .type_tag = .text },
    };
    defer for (&columns) |*column| column.deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    var name: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "Ada") };
    defer name.deinit(std.testing.allocator);
    try eng.insert("customer", &.{ .{ .int = 1 }, name });
    var request = try compile(std.testing.allocator, "from customer\n| emit { name, id }");
    defer request.deinit(std.testing.allocator);
    var result = try execute(std.testing.allocator, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqualStrings("name", result.columns[0]);
    try std.testing.expectEqualStrings("Ada", result.cells[0][0].?);
}

test "limit bounds relation results" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-limit";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{.{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int }};
    defer columns[0].deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    try eng.insert("customer", &.{.{ .int = 1 }});
    try eng.insert("customer", &.{.{ .int = 2 }});
    var request = try compile(std.testing.allocator, "from customer\n| emit { id }\n| limit 1");
    defer request.deinit(std.testing.allocator);
    var result = try execute(std.testing.allocator, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);

    var zero_request = try compile(std.testing.allocator, "from customer\n| emit { id }\n| limit 0");
    defer zero_request.deinit(std.testing.allocator);
    var zero_result = try execute(std.testing.allocator, &eng, &zero_request);
    defer zero_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), zero_result.cells.len);
}

test "limit bounds observation evidence results" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-evidence-limit";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    _ = try eng.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "test-camera", "development", "first");
    _ = try eng.observe("camera_2", .image, "image/png", "2026-07-31T12:01:00+08:00", "test-camera", "development", "second");
    var request = try compile(std.testing.allocator, "from observation_evidence\n| emit { object_id }\n| limit 1");
    defer request.deinit(std.testing.allocator);
    var result = try execute(std.testing.allocator, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);
    try std.testing.expectEqualStrings("camera_1", result.cells[0][0].?);
}

test "renders an embedding projection as a vector literal" {
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |text| std.testing.allocator.free(text);
        owned.deinit(std.testing.allocator);
    }
    var embedding: value.Value = .{ .vector = try std.testing.allocator.dupe(f32, &.{ 1, 2.5 }) };
    defer embedding.deinit(std.testing.allocator);
    const rendered = (try program.valueToText(std.testing.allocator, &owned, embedding)).?;
    try std.testing.expectEqualStrings("[1,2.5]", rendered);
}

test "where filters a relation before projection and limit" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-where";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try std.testing.allocator.dupe(u8, "region"), .type_tag = .text },
        .{ .name = try std.testing.allocator.dupe(u8, "score"), .type_tag = .int },
    };
    defer for (&columns) |*column| column.deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    var north: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "north") };
    defer north.deinit(std.testing.allocator);
    var south: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "south") };
    defer south.deinit(std.testing.allocator);
    try eng.insert("customer", &.{ .{ .int = 1 }, north, .{ .int = 30 } });
    try eng.insert("customer", &.{ .{ .int = 2 }, south, .{ .int = 10 } });
    try eng.insert("customer", &.{ .{ .int = 3 }, north, .{ .int = 40 } });

    var request = try compile(std.testing.allocator, "from customer\n| where region = 'north'\n| where score > 25\n| emit { id }\n| limit 1");
    defer request.deinit(std.testing.allocator);
    var result = try execute(std.testing.allocator, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);
    try std.testing.expectEqualStrings("1", result.cells[0][0].?);
}

test "where supports membership, null, and pattern predicates" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-where-ops";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try std.testing.allocator.dupe(u8, "name"), .type_tag = .text },
        .{ .name = try std.testing.allocator.dupe(u8, "region"), .type_tag = .text },
        .{ .name = try std.testing.allocator.dupe(u8, "active"), .type_tag = .bool },
    };
    defer for (&columns) |*column| column.deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    var ada: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "ada") };
    defer ada.deinit(std.testing.allocator);
    var bob: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "bob") };
    defer bob.deinit(std.testing.allocator);
    var ann: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "ann") };
    defer ann.deinit(std.testing.allocator);
    var north: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "north") };
    defer north.deinit(std.testing.allocator);
    try eng.insert("customer", &.{ .{ .int = 1 }, ada, .null, .{ .bool = true } });
    try eng.insert("customer", &.{ .{ .int = 2 }, bob, north, .{ .bool = false } });
    try eng.insert("customer", &.{ .{ .int = 3 }, ann, north, .{ .bool = true } });

    var membership = try compile(std.testing.allocator, "from customer\n| where id in (1, 3)\n| emit { id }");
    defer membership.deinit(std.testing.allocator);
    var membership_result = try execute(std.testing.allocator, &eng, &membership);
    defer membership_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), membership_result.cells.len);
    try std.testing.expectEqualStrings("1", membership_result.cells[0][0].?);
    try std.testing.expectEqualStrings("3", membership_result.cells[1][0].?);

    var not_in = try compile(std.testing.allocator, "from customer\n| where id not in (1, 2)\n| emit { id }");
    defer not_in.deinit(std.testing.allocator);
    var not_in_result = try execute(std.testing.allocator, &eng, &not_in);
    defer not_in_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), not_in_result.cells.len);

    var nulls = try compile(std.testing.allocator, "from customer\n| where region is null\n| emit { id }");
    defer nulls.deinit(std.testing.allocator);
    var nulls_result = try execute(std.testing.allocator, &eng, &nulls);
    defer nulls_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), nulls_result.cells.len);
    try std.testing.expectEqualStrings("1", nulls_result.cells[0][0].?);

    var patterned = try compile(std.testing.allocator, "from customer\n| where name like 'a%'\n| emit { name }");
    defer patterned.deinit(std.testing.allocator);
    var patterned_result = try execute(std.testing.allocator, &eng, &patterned);
    defer patterned_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), patterned_result.cells.len);

    var boolean = try compile(std.testing.allocator, "from customer\n| where active = true\n| where name != 'bob'\n| emit { id }");
    defer boolean.deinit(std.testing.allocator);
    var boolean_result = try execute(std.testing.allocator, &eng, &boolean);
    defer boolean_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), boolean_result.cells.len);
}

test "where filters observation evidence by typed fields" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-where-evidence";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    _ = try eng.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "test-camera", "development", "first payload");
    _ = try eng.observe("camera_2", .audio, "audio/ogg", "2026-07-31T12:01:00+08:00", "test-mic", "development", "second payload");

    var by_object = try compile(std.testing.allocator, "from observation_evidence\n| where object_id = 'camera_2'\n| emit { evidence_id, modality }\n| limit 1");
    defer by_object.deinit(std.testing.allocator);
    var by_object_result = try execute(std.testing.allocator, &eng, &by_object);
    defer by_object_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), by_object_result.cells.len);
    try std.testing.expectEqualStrings("audio", by_object_result.cells[0][1].?);

    var by_id = try compile(std.testing.allocator, "from observation_evidence\n| where evidence_id = 1\n| emit { object_id }\n| limit 1");
    defer by_id.deinit(std.testing.allocator);
    var by_id_result = try execute(std.testing.allocator, &eng, &by_id);
    defer by_id_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), by_id_result.cells.len);
    try std.testing.expectEqualStrings("camera_1", by_id_result.cells[0][0].?);

    var by_length = try compile(std.testing.allocator, "from observation_evidence\n| where payload_length >= 14\n| emit { object_id }\n| limit 1");
    defer by_length.deinit(std.testing.allocator);
    var by_length_result = try execute(std.testing.allocator, &eng, &by_length);
    defer by_length_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), by_length_result.cells.len);
    try std.testing.expectEqualStrings("camera_2", by_length_result.cells[0][0].?);
}

test "emit through a transaction reads its own staged writes" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-exec-tx";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try std.testing.allocator.dupe(u8, "name"), .type_tag = .text },
    };
    defer for (&columns) |*column| column.deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    var ada: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "Ada") };
    defer ada.deinit(std.testing.allocator);
    try eng.insert("customer", &.{ .{ .int = 1 }, ada });

    var tx = eng.beginTransaction();
    defer tx.deinit();
    var grace: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "Grace") };
    defer grace.deinit(std.testing.allocator);
    try eng.stageInsert(&tx, "customer", &.{ .{ .int = 2 }, grace });

    // Without the transaction, only committed rows are visible.
    var plain_request = try compile(std.testing.allocator, "from customer\n| emit { id, name }");
    defer plain_request.deinit(std.testing.allocator);
    var plain = try execute(std.testing.allocator, &eng, &plain_request);
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 1), plain.cells.len);

    // Through the transaction, the staged row is visible too.
    var tx_request = try compile(std.testing.allocator, "from customer\n| emit { id, name }");
    defer tx_request.deinit(std.testing.allocator);
    var result = try executeTx(std.testing.allocator, &eng, &tx_request, &tx);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.cells.len);
    try std.testing.expectEqualStrings("2", result.cells[1][0].?);
    try std.testing.expectEqualStrings("Grace", result.cells[1][1].?);
}

test "emit through a transaction applies where over merged rows" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-exec-tx-where";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try std.testing.allocator.dupe(u8, "region"), .type_tag = .text },
    };
    defer for (&columns) |*column| column.deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    var north: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "north") };
    defer north.deinit(std.testing.allocator);
    var south: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "south") };
    defer south.deinit(std.testing.allocator);
    try eng.insert("customer", &.{ .{ .int = 1 }, north });

    var tx = eng.beginTransaction();
    defer tx.deinit();
    try eng.stageInsert(&tx, "customer", &.{ .{ .int = 2 }, south });

    // A predicate is evaluated against the merged row set: the staged row is
    // filtered like any committed row.
    var request = try compile(std.testing.allocator, "from customer\n| where region = 'south'\n| emit { id }");
    defer request.deinit(std.testing.allocator);
    var result = try executeTx(std.testing.allocator, &eng, &request, &tx);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);
    try std.testing.expectEqualStrings("2", result.cells[0][0].?);
}

test "where binding rejects unknown columns and type mismatches" {
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-where-errors";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(std.testing.allocator, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try std.testing.allocator.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try std.testing.allocator.dupe(u8, "name"), .type_tag = .text },
        .{ .name = try std.testing.allocator.dupe(u8, "active"), .type_tag = .bool },
    };
    defer for (&columns) |*column| column.deinit(std.testing.allocator);
    try eng.createTable("customer", &columns);
    var ada: value.Value = .{ .text = try std.testing.allocator.dupe(u8, "ada") };
    defer ada.deinit(std.testing.allocator);
    try eng.insert("customer", &.{ .{ .int = 1 }, ada, .{ .bool = true } });

    var unknown = try compile(std.testing.allocator, "from customer\n| where missing = 1\n| emit { id }");
    defer unknown.deinit(std.testing.allocator);
    try std.testing.expectError(error.FieldNotFound, execute(std.testing.allocator, &eng, &unknown));

    var mismatch = try compile(std.testing.allocator, "from customer\n| where id = 'x'\n| emit { id }");
    defer mismatch.deinit(std.testing.allocator);
    try std.testing.expectError(error.TypeMismatch, execute(std.testing.allocator, &eng, &mismatch));

    var comparable = try compile(std.testing.allocator, "from customer\n| where active > true\n| emit { id }");
    defer comparable.deinit(std.testing.allocator);
    try std.testing.expectError(error.NonComparableColumn, execute(std.testing.allocator, &eng, &comparable));

    var pattern_type = try compile(std.testing.allocator, "from customer\n| where id like '1%'\n| emit { id }");
    defer pattern_type.deinit(std.testing.allocator);
    try std.testing.expectError(error.TypeMismatch, execute(std.testing.allocator, &eng, &pattern_type));
}

test "dotted paths parse and bind as identifier paths" {
    const gpa = std.testing.allocator;
    var parsed = try ast.parse(gpa, "from customer\n| where author.name = 'ada'\n| where title like 'a%'\n| emit { author.name, title }\n| limit 5");
    defer parsed.deinit(gpa);
    try std.testing.expectEqualStrings("author.name", parsed.where[0].column);
    try std.testing.expectEqualStrings("title", parsed.where[1].column);
    try std.testing.expectEqualStrings("author.name", parsed.fields[0]);
    try std.testing.expectEqual(@as(?u32, 5), parsed.limit);

    // The canonical IR accepts the dotted-path shape; a trailing dot or empty
    // segment is rejected as an identifier.
    var request = try ir.bind(gpa, parsed);
    defer request.deinit(gpa);
    try std.testing.expectEqualStrings("author.name", request.fields[0]);

    try std.testing.expect(!ast.isPath("author."));
    try std.testing.expect(!ast.isPath("author..name"));
    try std.testing.expect(!ast.isPath(".name"));
    try std.testing.expect(ast.isPath("author.name"));
    try std.testing.expect(ast.isPath("id"));
}

test "source and equivalent canonical IR produce the same result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-ir-equivalence";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{
        .{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true },
        .{ .name = try gpa.dupe(u8, "name"), .type_tag = .text },
        .{ .name = try gpa.dupe(u8, "region"), .type_tag = .text },
    };
    defer for (&columns) |*column| column.deinit(gpa);
    try eng.createTable("customer", &columns);
    var ada: value.Value = .{ .text = try gpa.dupe(u8, "ada") };
    defer ada.deinit(gpa);
    var ann: value.Value = .{ .text = try gpa.dupe(u8, "ann") };
    defer ann.deinit(gpa);
    var north: value.Value = .{ .text = try gpa.dupe(u8, "north") };
    defer north.deinit(gpa);
    var south: value.Value = .{ .text = try gpa.dupe(u8, "south") };
    defer south.deinit(gpa);
    try eng.insert("customer", &.{ .{ .int = 1 }, ada, north });
    try eng.insert("customer", &.{ .{ .int = 2 }, ann, north });
    try eng.insert("customer", &.{ .{ .int = 3 }, ann, south });

    const source = "from customer\n| where region = 'north'\n| emit { id, name }\n| limit 10";

    // Execute the bound source request directly...
    var request_a = try compile(gpa, source);
    defer request_a.deinit(gpa);
    var result_a = try execute(gpa, &eng, &request_a);
    defer result_a.deinit();

    // ...then execute the identical request recovered from its canonical IR
    // bytes, exactly as the Wire Protocol's FLOW_IR path would.
    const bytes = try ir.encode(gpa, &request_a);
    defer gpa.free(bytes);
    var request_b = try ir.decode(gpa, bytes);
    defer request_b.deinit(gpa);
    var result_b = try execute(gpa, &eng, &request_b);
    defer result_b.deinit();

    try std.testing.expectEqual(result_a.columns.len, result_b.columns.len);
    try std.testing.expectEqual(result_a.cells.len, result_b.cells.len);
    for (result_a.columns, 0..) |column, index| try std.testing.expectEqualStrings(column, result_b.columns[index]);
    for (result_a.cells, 0..) |row, row_index| {
        for (row, 0..) |cell, col_index| {
            try std.testing.expectEqualStrings(cell.?, result_b.cells[row_index][col_index].?);
        }
    }
}

test "source and equivalent IR produce the same error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-ir-error-equivalence";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
    defer columns[0].deinit(gpa);
    try eng.createTable("customer", &columns);

    // A source that names an unknown field fails binding; the equivalent IR
    // (encoded from the bound request, which only differs in that the source
    // already failed) must fail identically. Encoding a request whose field is
    // unknown at execution still round-trips; the failure is at execution.
    const source = "from customer\n| emit { missing }";
    var request_a = try compile(gpa, source);
    defer request_a.deinit(gpa);
    try std.testing.expectError(error.FieldNotFound, execute(gpa, &eng, &request_a));

    const bytes = try ir.encode(gpa, &request_a);
    defer gpa.free(bytes);
    var request_b = try ir.decode(gpa, bytes);
    defer request_b.deinit(gpa);
    try std.testing.expectError(error.FieldNotFound, execute(gpa, &eng, &request_b));

    // An unresolvable relation produces the same error from source and IR.
    const missing_rel = "from nobody\n| emit { id }";
    var rel_a = try compile(gpa, missing_rel);
    defer rel_a.deinit(gpa);
    try std.testing.expectError(error.SemanticNameNotFound, execute(gpa, &eng, &rel_a));
    const rel_bytes = try ir.encode(gpa, &rel_a);
    defer gpa.free(rel_bytes);
    var rel_b = try ir.decode(gpa, rel_bytes);
    defer rel_b.deinit(gpa);
    try std.testing.expectError(error.SemanticNameNotFound, execute(gpa, &eng, &rel_b));
}

// ── Document collection slice (roadmap Phase 2) ──

fn insertTestDocuments(gpa: Allocator, eng: *engine_mod.Engine) !void {
    try eng.createDocument("books");
    var dune: [3]document_mod.Field = undefined;
    dune[0] = .{ .path = try gpa.dupe(u8, "title"), .item = .{ .text = try gpa.dupe(u8, "Dune") } };
    dune[1] = .{ .path = try gpa.dupe(u8, "author.name"), .item = .{ .text = try gpa.dupe(u8, "Herbert") } };
    dune[2] = .{ .path = try gpa.dupe(u8, "pages"), .item = .{ .int = 412 } };
    defer for (&dune) |*f| f.deinit(gpa);
    try eng.insertDocument("books", "1", &dune);

    var snow: [3]document_mod.Field = undefined;
    snow[0] = .{ .path = try gpa.dupe(u8, "title"), .item = .{ .text = try gpa.dupe(u8, "Snow Crash") } };
    snow[1] = .{ .path = try gpa.dupe(u8, "author.name"), .item = .{ .text = try gpa.dupe(u8, "Stephenson") } };
    snow[2] = .{ .path = try gpa.dupe(u8, "pages"), .item = .{ .int = 480 } };
    defer for (&snow) |*f| f.deinit(gpa);
    try eng.insertDocument("books", "2", &snow);
}

test "reads a document collection with path projection and predicates" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-documents";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestDocuments(gpa, &eng);

    var request = try compile(gpa, "from books\n| where author.name = 'Herbert'\n| emit { title, author.name, pages }\n| limit 5");
    defer request.deinit(gpa);
    var result = try execute(gpa, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);
    try std.testing.expectEqualStrings("title", result.columns[0]);
    try std.testing.expectEqualStrings("author.name", result.columns[1]);
    try std.testing.expectEqualStrings("pages", result.columns[2]);
    try std.testing.expectEqualStrings("Dune", result.cells[0][0].?);
    try std.testing.expectEqualStrings("Herbert", result.cells[0][1].?);
    try std.testing.expectEqualStrings("412", result.cells[0][2].?);

    // Numeric predicate over a path; a path absent from a document reads null
    // and never matches.
    var pages = try compile(gpa, "from books\n| where pages >= 450\n| emit { title }");
    defer pages.deinit(gpa);
    var pages_result = try execute(gpa, &eng, &pages);
    defer pages_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), pages_result.cells.len);
    try std.testing.expectEqualStrings("Snow Crash", pages_result.cells[0][0].?);

    var absent = try compile(gpa, "from books\n| where genre = 'scifi'\n| emit { title, genre }");
    defer absent.deinit(gpa);
    var absent_result = try execute(gpa, &eng, &absent);
    defer absent_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), absent_result.cells.len);
}

test "document source and equivalent IR produce the same result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-document-ir";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestDocuments(gpa, &eng);

    const source = "from books\n| where pages > 400\n| emit { title, author.name }";
    var request_a = try compile(gpa, source);
    defer request_a.deinit(gpa);
    var result_a = try execute(gpa, &eng, &request_a);
    defer result_a.deinit();

    const bytes = try ir.encode(gpa, &request_a);
    defer gpa.free(bytes);
    var request_b = try ir.decode(gpa, bytes);
    defer request_b.deinit(gpa);
    var result_b = try execute(gpa, &eng, &request_b);
    defer result_b.deinit();

    try std.testing.expectEqual(result_a.cells.len, result_b.cells.len);
    try std.testing.expectEqual(@as(usize, 2), result_a.cells.len);
    for (result_a.cells, 0..) |row, i| {
        try std.testing.expectEqualStrings(row[0].?, result_b.cells[i][0].?);
        try std.testing.expectEqualStrings(row[1].?, result_b.cells[i][1].?);
    }
}

test "reading an unknown name still fails when a document collection exists" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-document-missing";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestDocuments(gpa, &eng);

    var request = try compile(gpa, "from nothing\n| emit { title }");
    defer request.deinit(gpa);
    try std.testing.expectError(error.SemanticNameNotFound, execute(gpa, &eng, &request));
}

fn insertTestGraph(gpa: Allocator, eng: *engine_mod.Engine) !void {
    var ada: [1]document_mod.Field = undefined;
    ada[0] = .{ .path = try gpa.dupe(u8, "name"), .item = .{ .text = try gpa.dupe(u8, "Ada") } };
    defer for (&ada) |*f| f.deinit(gpa);
    var grace: [1]document_mod.Field = undefined;
    grace[0] = .{ .path = try gpa.dupe(u8, "name"), .item = .{ .text = try gpa.dupe(u8, "Grace") } };
    defer for (&grace) |*f| f.deinit(gpa);
    var lin: [1]document_mod.Field = undefined;
    lin[0] = .{ .path = try gpa.dupe(u8, "name"), .item = .{ .text = try gpa.dupe(u8, "Lin") } };
    defer for (&lin) |*f| f.deinit(gpa);

    try eng.addNode("social", "1", &ada);
    try eng.addNode("social", "2", &grace);
    try eng.addNode("social", "3", &lin);
    try eng.addEdge("social", "1", "mentors", "2");
    try eng.addEdge("social", "1", "mentors", "3");
    try eng.addEdge("social", "2", "collaborates", "3");
}

test "navigate follows labeled edges and projects source and destination fields" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-graph";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestGraph(gpa, &eng);

    // Ada mentors Grace and Lin: navigate returns one row per matching edge,
    // with the source node's name and the destination under the alias.
    var request = try compile(gpa, "from social\n| navigate mentors as mentee\n| emit { name, mentee.name }\n| limit 5");
    defer request.deinit(gpa);
    var result = try execute(gpa, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.cells.len);
    try std.testing.expectEqualStrings("Ada", result.cells[0][0].?);
    try std.testing.expectEqualStrings("Grace", result.cells[0][1].?);
    try std.testing.expectEqualStrings("Ada", result.cells[1][0].?);
    try std.testing.expectEqualStrings("Lin", result.cells[1][1].?);

    // A node with no matching outgoing edge produces no row.
    var none = try compile(gpa, "from social\n| navigate collaborates as peer\n| where name = 'Ada'\n| emit { name, peer.name }");
    defer none.deinit(gpa);
    var none_result = try execute(gpa, &eng, &none);
    defer none_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), none_result.cells.len);

    // Without navigate, nodes read like documents.
    var plain = try compile(gpa, "from social\n| emit { name }\n| limit 2");
    defer plain.deinit(gpa);
    var plain_result = try execute(gpa, &eng, &plain);
    defer plain_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), plain_result.cells.len);
    try std.testing.expectEqualStrings("Ada", plain_result.cells[0][0].?);
}

test "graph source and equivalent IR produce the same navigate result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-graph-ir";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestGraph(gpa, &eng);

    const source = "from social\n| navigate mentors as mentee\n| emit { name, mentee.name }\n| limit 5";
    var request_a = try compile(gpa, source);
    defer request_a.deinit(gpa);
    var result_a = try execute(gpa, &eng, &request_a);
    defer result_a.deinit();

    const bytes = try ir.encode(gpa, &request_a);
    defer gpa.free(bytes);
    var request_b = try ir.decode(gpa, bytes);
    defer request_b.deinit(gpa);
    var result_b = try execute(gpa, &eng, &request_b);
    defer result_b.deinit();

    try std.testing.expectEqual(result_a.cells.len, result_b.cells.len);
    try std.testing.expectEqual(@as(usize, 2), result_a.cells.len);
    for (result_a.cells, 0..) |row, i| {
        try std.testing.expectEqualStrings(row[0].?, result_b.cells[i][0].?);
        try std.testing.expectEqualStrings(row[1].?, result_b.cells[i][1].?);
    }
}

test "navigate on a relation is rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-graph-reject";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
    defer columns[0].deinit(gpa);
    try eng.createTable("customer", &columns);

    var request = try compile(gpa, "from customer\n| navigate orders as order\n| emit { id }");
    defer request.deinit(gpa);
    try std.testing.expectError(error.UnsupportedNavigate, execute(gpa, &eng, &request));
}

// ── KV collection slice (roadmap Phase 2) ──

/// Seed a KV collection exactly as the CLI/IR ingest would: a put into a
/// nonexistent collection creates it (self-contained ingest).
fn insertTestKv(gpa: Allocator, eng: *engine_mod.Engine) !void {
    var dark: value.Value = .{ .text = try gpa.dupe(u8, "dark") };
    defer dark.deinit(gpa);
    try eng.putKv("settings", "theme", dark);
    try eng.putKv("settings", "retries", .{ .int = 3 });
    var beta: value.Value = .{ .text = try gpa.dupe(u8, "enabled") };
    defer beta.deinit(gpa);
    try eng.putKv("settings", "beta", beta);
}

test "kv collections read key and value with predicates and upsert" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-kv";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestKv(gpa, &eng);

    // A point read by key: `key` is text, `value` is the scalar.
    var request = try compile(gpa, "from settings\n| where key = 'theme'\n| emit { key, value }\n| limit 5");
    defer request.deinit(gpa);
    var result = try execute(gpa, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);
    try std.testing.expectEqualStrings("key", result.columns[0]);
    try std.testing.expectEqualStrings("value", result.columns[1]);
    try std.testing.expectEqualStrings("theme", result.cells[0][0].?);
    try std.testing.expectEqualStrings("dark", result.cells[0][1].?);

    // A predicate on the value filters typed scalars; an absent key matches
    // nothing.
    var numeric = try compile(gpa, "from settings\n| where value = 3\n| emit { key }");
    defer numeric.deinit(gpa);
    var numeric_result = try execute(gpa, &eng, &numeric);
    defer numeric_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), numeric_result.cells.len);
    try std.testing.expectEqualStrings("retries", numeric_result.cells[0][0].?);

    var absent = try compile(gpa, "from settings\n| where key = 'missing'\n| emit { key, value }");
    defer absent.deinit(gpa);
    var absent_result = try execute(gpa, &eng, &absent);
    defer absent_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), absent_result.cells.len);

    // Upsert replaces the value in place; insertion order is stable.
    try eng.putKv("settings", "retries", .{ .int = 9 });
    var all = try compile(gpa, "from settings\n| emit { key, value }");
    defer all.deinit(gpa);
    var all_result = try execute(gpa, &eng, &all);
    defer all_result.deinit();
    try std.testing.expectEqual(@as(usize, 3), all_result.cells.len);
    try std.testing.expectEqualStrings("theme", all_result.cells[0][0].?);
    try std.testing.expectEqualStrings("retries", all_result.cells[1][0].?);
    try std.testing.expectEqualStrings("9", all_result.cells[1][1].?);
    try std.testing.expectEqualStrings("beta", all_result.cells[2][0].?);
}

test "kv source and equivalent IR produce the same result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-kv-ir";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestKv(gpa, &eng);

    const source = "from settings\n| where value = 3\n| emit { key, value }";
    var request_a = try compile(gpa, source);
    defer request_a.deinit(gpa);
    var result_a = try execute(gpa, &eng, &request_a);
    defer result_a.deinit();

    const bytes = try ir.encode(gpa, &request_a);
    defer gpa.free(bytes);
    var request_b = try ir.decode(gpa, bytes);
    defer request_b.deinit(gpa);
    var result_b = try execute(gpa, &eng, &request_b);
    defer result_b.deinit();

    try std.testing.expectEqual(result_a.cells.len, result_b.cells.len);
    try std.testing.expectEqual(@as(usize, 1), result_a.cells.len);
    for (result_a.cells, 0..) |row, i| {
        try std.testing.expectEqualStrings(row[0].?, result_b.cells[i][0].?);
        try std.testing.expectEqualStrings(row[1].?, result_b.cells[i][1].?);
    }
}

test "kv collections survive restart recovery" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-kv-restart";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    {
        var eng = try engine_mod.Engine.open(gpa, io, dir, false);
        defer eng.deinit();
        try insertTestKv(gpa, &eng);
    }
    {
        var eng = try engine_mod.Engine.open(gpa, io, dir, false);
        defer eng.deinit();
        var request = try compile(gpa, "from settings\n| emit { key, value }");
        defer request.deinit(gpa);
        var result = try execute(gpa, &eng, &request);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 3), result.cells.len);
        try std.testing.expectEqualStrings("theme", result.cells[0][0].?);
        try std.testing.expectEqualStrings("dark", result.cells[0][1].?);
        try std.testing.expectEqualStrings("retries", result.cells[1][0].?);
        try std.testing.expectEqualStrings("3", result.cells[1][1].?);
        try std.testing.expectEqualStrings("beta", result.cells[2][0].?);
    }
}

test "kv collections survive checkpoint and restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-kv-ckpt";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    {
        var eng = try engine_mod.Engine.open(gpa, io, dir, false);
        defer eng.deinit();
        try insertTestKv(gpa, &eng);
        // A checkpoint rewrites the WAL to reconstruct current state; the KV
        // records are re-emitted as create_kv + kv_put.
        _ = try eng.checkpoint();
    }
    {
        var eng = try engine_mod.Engine.open(gpa, io, dir, false);
        defer eng.deinit();
        var request = try compile(gpa, "from settings\n| where key = 'theme'\n| emit { key, value }");
        defer request.deinit(gpa);
        var result = try execute(gpa, &eng, &request);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.cells.len);
        try std.testing.expectEqualStrings("dark", result.cells[0][1].?);
    }
}

test "kv rejects a vector value and keeps the collection unmodified" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-kv-reject";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try eng.putKv("settings", "ok", .{ .int = 1 });

    var embedding: value.Value = .{ .vector = try gpa.dupe(f32, &.{ 1, 2 }) };
    defer embedding.deinit(gpa);
    try std.testing.expectError(error.UnsupportedValue, eng.putKv("settings", "bad", embedding));
    try std.testing.expectError(error.MissingKey, eng.putKv("settings", "", .{ .int = 1 }));

    var request = try compile(gpa, "from settings\n| emit { key }");
    defer request.deinit(gpa);
    var result = try execute(gpa, &eng, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);
    try std.testing.expectEqualStrings("ok", result.cells[0][0].?);
}

// ── Cooperative cancellation probe (roadmap Phase 6) ──

/// Test probe that permits `remaining` bounded work units and then reports
/// cancellation, mirroring a Connection whose statement was marked by a
/// `CANCEL_REQUEST` while the scan was between two rows.
const CountingProbe = struct {
    remaining: usize,

    fn check(ctx: *anyopaque) error{Canceled}!void {
        const self: *CountingProbe = @ptrCast(@alignCast(ctx));
        if (self.remaining == 0) return error.Canceled;
        self.remaining -= 1;
    }
};

fn probeOpts(probe: *CountingProbe) ExecOptions {
    return .{ .cancel = .{ .ctx = probe, .check = CountingProbe.check } };
}

test "a cancellation probe stops a relation scan between bounded work units" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-cancel-relation";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
    defer columns[0].deinit(gpa);
    try eng.createTable("items", &columns);
    for (0..10) |i| try eng.insert("items", &.{.{ .int = @intCast(i) }});

    var request = try compile(gpa, "from items\n| emit { id }");
    defer request.deinit(gpa);

    // A probe that never fires leaves the scan untouched: identical result to
    // the plain execute path.
    var silent = CountingProbe{ .remaining = std.math.maxInt(usize) };
    var full = try executeOpts(gpa, &eng, &request, probeOpts(&silent));
    defer full.deinit();
    try std.testing.expectEqual(@as(usize, 10), full.cells.len);

    // A probe that fires after three rows stops the scan with error.Canceled;
    // the partially built result and the snapshot are released by the error
    // path, so the engine lock remains available to the caller.
    var firing = CountingProbe{ .remaining = 3 };
    try std.testing.expectError(error.Canceled, executeOpts(gpa, &eng, &request, probeOpts(&firing)));
}

test "a cancellation probe stops document and navigate scans" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-cancel-doc-graph";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    try insertTestDocuments(gpa, &eng);
    try insertTestGraph(gpa, &eng);

    var doc_request = try compile(gpa, "from books\n| emit { title }");
    defer doc_request.deinit(gpa);
    var doc_probe = CountingProbe{ .remaining = 1 };
    try std.testing.expectError(error.Canceled, executeOpts(gpa, &eng, &doc_request, probeOpts(&doc_probe)));

    var nav_request = try compile(gpa, "from social\n| navigate mentors as mentee\n| emit { name, mentee.name }");
    defer nav_request.deinit(gpa);
    var nav_probe = CountingProbe{ .remaining = 1 };
    try std.testing.expectError(error.Canceled, executeOpts(gpa, &eng, &nav_request, probeOpts(&nav_probe)));

    // The evidence view observes the same cooperative boundary: the scan loop
    // checks the probe per committed observation record.
    _ = try eng.observe("camera_1", .image, "image/png", "2026-07-31T12:00:00+08:00", "test-camera", "development", "payload");
    var ev_probe = CountingProbe{ .remaining = 0 };
    var ev_request = try compile(gpa, "from observation_evidence\n| emit { object_id }");
    defer ev_request.deinit(gpa);
    try std.testing.expectError(error.Canceled, executeOpts(gpa, &eng, &ev_request, probeOpts(&ev_probe)));
}

test "a cancellation probe applies to transaction-scoped reads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "zig-cache/runadb-flow-cancel-tx";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    var eng = try engine_mod.Engine.open(gpa, io, dir, false);
    defer eng.deinit();
    var columns = [_]value.Column{.{ .name = try gpa.dupe(u8, "id"), .type_tag = .int, .primary_key = true }};
    defer columns[0].deinit(gpa);
    try eng.createTable("items", &columns);
    for (0..10) |i| try eng.insert("items", &.{.{ .int = @intCast(i) }});

    var request = try compile(gpa, "from items\n| emit { id }");
    defer request.deinit(gpa);
    var tx = eng.beginTransaction();
    defer tx.deinit();
    var probe = CountingProbe{ .remaining = 2 };
    try std.testing.expectError(error.Canceled, executeTxOpts(gpa, &eng, &request, &tx, probeOpts(&probe)));
}
