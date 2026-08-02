const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bytes = @import("../util/bytes.zig");
const value = @import("value.zig");
const evidence = @import("evidence.zig");
const vfs_mod = @import("vfs.zig");

pub const RecordType = enum(u8) {
    create_table = 1,
    insert = 2,
    update = 3,
    delete = 4,
    add_column = 5,
    drop_column = 6,
    set_default = 7,
    set_not_null = 8,
    /// Atomic multi-op commit: all nested ops share one frame/CRC.
    /// Recovery applies every nested op or none (torn tail drops the whole batch).
    txn_batch = 9,
    /// Authoritative SERIAL counter for a table. Only the checkpoint path emits
    /// this: replaying inserts alone would rewind the counter past rows that
    /// were deleted, letting a later INSERT reuse a retired identifier.
    /// Requires WAL format version 2.
    set_serial = 10,
    /// Immutable Observation Evidence metadata. Payload bytes live in the
    /// versioned payload store and are validated before this record is applied.
    observe = 11,
    /// Authoritative published commit watermark. Only the checkpoint path emits
    /// this: replaying reconstruction records alone would reset the watermark to
    /// zero, which would make every pre-checkpoint row look created at seq 0 and
    /// break MVCC ordering after restart. Requires WAL format version 5.
    set_commit_seq = 12,
};

/// One DML op inside an explicit-transaction commit batch.
pub const TxnOp = union(enum) {
    insert: InsertRecord,
    update: UpdateRecord,
    delete: DeleteRecord,

    pub const Tag = enum {
        insert,
        update,
        delete,
    };
};

/// WAL files are self-identifying so a changed frame layout never reinterprets old bytes.
///
/// Frame layout (little-endian):
///   [payload_len: u32][crc32: u32][payload: payload_len bytes]
/// where crc32 covers `payload_len` (as raw LE bytes) concatenated with `payload`.
/// Covering the length prevents a flipped length field from being accepted as a
/// different complete frame; only an incomplete tail may be truncated.
const file_magic = "RUNADB_WAL";
/// Version written into every new or rewritten WAL file.
///
/// Version 5: `txn_batch` records carry a leading `commit_seq: u64`, and the
/// checkpoint path emits `set_commit_seq` to restore the published watermark.
/// Recovery rebuilds the MVCC watermark from these records.
const format_version: u32 = 5;
/// Oldest version this build still replays. Version 1 files contain no
/// `set_serial` record, so reading them needs no compatibility shim; only a
/// checkpoint rewrite upgrades a file in place. An older build meeting a
/// version-2 file rejects it with `UnsupportedWalFormat` rather than
/// misreading `set_serial` as corruption.
const format_version_min: u32 = 1;
const file_header_len = file_magic.len + @sizeOf(u32);
const frame_header_len = @sizeOf(u32) + @sizeOf(u32);
const frame_payload_len_max = 8 * 1024 * 1024;
/// Most OLTP frames fit here; avoids a heap allocation on the sync path.
const small_frame_cap = 1024;

pub const CreateTableRecord = struct {
    name: []const u8,
    columns: []const value.Column,
};

pub const InsertRecord = struct {
    table: []const u8,
    values: []const value.Value,
};

/// Full-row replacement addressed by primary key value.
pub const UpdateRecord = struct {
    table: []const u8,
    pk: value.Value,
    values: []const value.Value,
};

pub const DeleteRecord = struct {
    table: []const u8,
    pk: value.Value,
};

/// Restores a table's SERIAL counter exactly, independent of its surviving rows.
pub const SetSerialRecord = struct { table: []const u8, next_serial: i64 };

pub const AddColumnRecord = struct { table: []const u8, column: value.Column };
pub const DropColumnRecord = struct { table: []const u8, column: []const u8 };
pub const SetDefaultRecord = struct { table: []const u8, column: []const u8, default_expr: value.DefaultExpr };
pub const SetNotNullRecord = struct { table: []const u8, column: []const u8, enabled: bool };
pub const ObserveRecord = evidence.Metadata;

/// Append-only WAL with a versioned file header and checksummed LE frames.
pub const Wal = struct {
    gpa: Allocator,
    io: Io,
    vfs: vfs_mod.Vfs,
    file: vfs_mod.File,
    /// Next write offset (end of file).
    offset: u64,
    /// Format version read from the file header, so record parsing can be
    /// version-aware during replay (e.g. v5 `txn_batch` carries `commit_seq`).
    file_version: u32,
    sync_on_append: bool,
    /// Serializes positional writes and allocation of WAL offsets.
    append_mutex: Io.Mutex = .init,
    /// Coordinates a durability round independently of WAL writes. This lets
    /// appends that arrive while a sync is in flight share that sync.
    sync_mutex: Io.Mutex = .init,
    sync_cond: Io.Condition = .init,
    durable_offset: u64,
    requested_durable_offset: u64,
    sync_in_progress: bool = false,
    sync_failed: bool = false,
    /// Set when a checkpoint published a new WAL file but failed to adopt the
    /// handle for it. `self.file` then refers to an unlinked inode, so further
    /// appends would be written where no recovery can ever find them. Fail every
    /// later append instead of accepting writes into a discarded file.
    unusable: bool = false,
    /// Number of `syncData` calls performed by group-commit leaders. Useful for
    /// tests that assert concurrent appenders share durability rounds.
    sync_rounds: u64 = 0,
    /// Test-only fault injection at the WAL-append boundary: when true, the
    /// next `appendTxnBatchGroup` call fails before any byte is written, so no
    /// WAL record becomes durable and every accepted request in the round is
    /// rejected with `WalAppendFailed`. Never set outside tests.
    test_fail_next_group_append: bool = false,

    pub const OpenError = Allocator.Error || Io.Dir.OpenError || Io.Dir.CreateDirPathOpenError || Io.File.OpenError || Io.File.StatError || Io.File.LengthError || error{
        InvalidWal,
        InvalidStoragePath,
        InstanceInUse,
        UnsupportedWalFormat,
        CorruptWal,
        WalUnusable,
        InputOutput,
        LockViolation,
        BrokenPipe,
        NotOpenForWriting,
        NotOpenForReading,
        Unseekable,
        EndOfStream,
        ReadFailed,
        WriteFailed,
        NameTooLong,
    };

    pub fn open(gpa: Allocator, io: Io, data_dir: []const u8, sync_on_append: bool) OpenError!Wal {
        var vfs = try vfs_mod.Vfs.open(io, data_dir);
        errdefer vfs.close();

        var file = try vfs.openFile("wal", .{ .create = true });
        errdefer file.close();

        var file_version: u32 = format_version;
        var len = try file.size();
        if (len == 0) {
            var header: [file_header_len]u8 = undefined;
            encodeFileHeader(&header);
            try file.writeAtAll(&header, 0);
            if (sync_on_append) try file.syncData();
            len = file_header_len;
        } else {
            const version = try validateFileHeader(&file, len);
            if (version > format_version) return error.UnsupportedWalFormat;
            file_version = version;
        }
        return .{
            .gpa = gpa,
            .io = io,
            .vfs = vfs,
            .file = file,
            .offset = len,
            .file_version = file_version,
            .sync_on_append = sync_on_append,
            .durable_offset = len,
            .requested_durable_offset = len,
        };
    }

    pub fn deinit(self: *Wal) void {
        self.file.close();
        self.vfs.close();
        self.* = undefined;
    }

    pub fn appendCreateTable(self: *Wal, rec: CreateTableRecord) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try encodeCreateTable(&list, self.gpa, rec);
        try self.appendPayload(list.items);
    }

    pub fn appendSetSerial(self: *Wal, rec: SetSerialRecord) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try encodeSetSerial(&list, self.gpa, rec);
        try self.appendPayload(list.items);
    }

    pub fn appendObserve(self: *Wal, rec: ObserveRecord) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try encodeObserve(&list, self.gpa, rec);
        try self.appendPayload(list.items);
    }

    pub fn appendInsert(self: *Wal, rec: InsertRecord) !void {
        try self.appendEncoded(struct {
            rec: InsertRecord,
            fn encode(ctx: @This(), list: *std.ArrayList(u8), gpa: Allocator) !void {
                try encodeInsert(list, gpa, ctx.rec);
            }
        }{ .rec = rec });
    }

    pub fn appendUpdate(self: *Wal, rec: UpdateRecord) !void {
        try self.appendEncoded(struct {
            rec: UpdateRecord,
            fn encode(ctx: @This(), list: *std.ArrayList(u8), gpa: Allocator) !void {
                try list.append(gpa, @intFromEnum(RecordType.update));
                try writeStr(list, gpa, ctx.rec.table);
                try writeValue(list, gpa, ctx.rec.pk);
                try writeU16(list, gpa, @intCast(ctx.rec.values.len));
                for (ctx.rec.values) |v| try writeValue(list, gpa, v);
            }
        }{ .rec = rec });
    }

    pub fn appendDelete(self: *Wal, rec: DeleteRecord) !void {
        try self.appendEncoded(struct {
            rec: DeleteRecord,
            fn encode(ctx: @This(), list: *std.ArrayList(u8), gpa: Allocator) !void {
                try list.append(gpa, @intFromEnum(RecordType.delete));
                try writeStr(list, gpa, ctx.rec.table);
                try writeValue(list, gpa, ctx.rec.pk);
            }
        }{ .rec = rec });
    }

    pub fn appendAddColumn(self: *Wal, rec: AddColumnRecord) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try list.append(self.gpa, @intFromEnum(RecordType.add_column));
        try writeStr(&list, self.gpa, rec.table);
        try writeColumn(&list, self.gpa, rec.column);
        try self.appendPayload(list.items);
    }

    pub fn appendDropColumn(self: *Wal, rec: DropColumnRecord) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try list.append(self.gpa, @intFromEnum(RecordType.drop_column));
        try writeStr(&list, self.gpa, rec.table);
        try writeStr(&list, self.gpa, rec.column);
        try self.appendPayload(list.items);
    }

    pub fn appendSetDefault(self: *Wal, rec: SetDefaultRecord) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try list.append(self.gpa, @intFromEnum(RecordType.set_default));
        try writeStr(&list, self.gpa, rec.table);
        try writeStr(&list, self.gpa, rec.column);
        try writeDefault(&list, self.gpa, rec.default_expr);
        try self.appendPayload(list.items);
    }

    pub fn appendSetNotNull(self: *Wal, rec: SetNotNullRecord) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try list.append(self.gpa, @intFromEnum(RecordType.set_not_null));
        try writeStr(&list, self.gpa, rec.table);
        try writeStr(&list, self.gpa, rec.column);
        try list.append(self.gpa, if (rec.enabled) 1 else 0);
        try self.appendPayload(list.items);
    }

    /// Persist a whole explicit-transaction write set as one checksummed frame.
    /// `commit_seq` is the MVCC commit sequence assigned by the single writer;
    /// recovery uses it to rebuild the published watermark.
    pub fn appendTxnBatch(self: *Wal, commit_seq: u64, ops: []const TxnOp) !void {
        if (ops.len == 0) return error.InvalidWal;
        if (ops.len > std.math.maxInt(u16)) return error.InvalidWal;

        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try list.append(self.gpa, @intFromEnum(RecordType.txn_batch));
        try writeU64(&list, self.gpa, commit_seq);
        try writeU16(&list, self.gpa, @intCast(ops.len));

        for (ops) |op| {
            var sub: std.ArrayList(u8) = .empty;
            defer sub.deinit(self.gpa);
            try encodeTxnOp(&sub, self.gpa, op);
            if (sub.items.len > std.math.maxInt(u32)) return error.InvalidWal;
            try writeU32(&list, self.gpa, @intCast(sub.items.len));
            try list.appendSlice(self.gpa, sub.items);
        }
        try self.appendPayload(list.items);
    }

    /// Persist the published commit watermark so recovery can restore it after
    /// a checkpoint has collapsed per-commit history into reconstruction
    /// records. Only the checkpoint path emits this record.
    pub fn appendSetCommitSeq(self: *Wal, commit_seq: u64) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try list.append(self.gpa, @intFromEnum(RecordType.set_commit_seq));
        try writeU64(&list, self.gpa, commit_seq);
        try self.appendPayload(list.items);
    }

    /// A batch of independent transaction commits prepared for one durability
    /// round. Each batch entry is its own `txn_batch` frame with its own
    /// `commit_seq`; group commit shares the WAL write and sync across them.
    pub const TxnBatchGroup = struct {
        commit_seq: u64,
        ops: []const TxnOp,
    };

    /// Append several `txn_batch` frames under one append-mutex hold and sync
    /// once through the end offset, so a group of commits pays a single
    /// durability round without merging their identity or commit order.
    pub fn appendTxnBatchGroup(self: *Wal, batches: []const TxnBatchGroup) !void {
        if (batches.len == 0) return error.InvalidWal;
        if (self.unusable) return error.WalUnusable;
        if (self.test_fail_next_group_append) {
            // Fail before any byte is written: no frame becomes durable, so no
            // accepted request may appear committed and restart exposes only
            // the prior confirmed prefix.
            self.test_fail_next_group_append = false;
            return error.WalUnusable;
        }

        const end_offset = blk: {
            try self.append_mutex.lock(self.io);
            defer self.append_mutex.unlock(self.io);

            var end = self.offset;
            for (batches) |batch| {
                if (batch.ops.len == 0 or batch.ops.len > std.math.maxInt(u16)) return error.InvalidWal;
                var list: std.ArrayList(u8) = .empty;
                defer list.deinit(self.gpa);
                try list.append(self.gpa, @intFromEnum(RecordType.txn_batch));
                try writeU64(&list, self.gpa, batch.commit_seq);
                try writeU16(&list, self.gpa, @intCast(batch.ops.len));
                for (batch.ops) |op| {
                    var sub: std.ArrayList(u8) = .empty;
                    defer sub.deinit(self.gpa);
                    try encodeTxnOp(&sub, self.gpa, op);
                    if (sub.items.len > std.math.maxInt(u32)) return error.InvalidWal;
                    try writeU32(&list, self.gpa, @intCast(sub.items.len));
                    try list.appendSlice(self.gpa, sub.items);
                }
                try self.writeFrameNoSync(list.items, end);
                end += frame_header_len + list.items.len;
            }
            self.offset = end;
            break :blk end;
        };
        if (self.sync_on_append) {
            try self.syncThrough(end_offset);
        }
    }

    /// Write one fully checksummed frame at `offset` without advancing the
    /// durable boundary. The caller owns ordering and the eventual sync.
    fn writeFrameNoSync(self: *Wal, payload: []const u8, offset: u64) !void {
        if (payload.len == 0 or payload.len > frame_payload_len_max) return error.InvalidWal;
        const frame_len = frame_header_len + payload.len;
        var stack_frame: [small_frame_cap]u8 = undefined;
        const use_stack = frame_len <= small_frame_cap;
        const frame = if (use_stack) stack_frame[0..frame_len] else try self.gpa.alloc(u8, frame_len);
        defer if (!use_stack) self.gpa.free(frame);

        const payload_len: u32 = @intCast(payload.len);
        bytes.writeU32LE(frame[0..4], payload_len);
        bytes.writeU32LE(frame[4..8], frameChecksum(payload_len, payload));
        @memcpy(frame[frame_header_len..], payload);
        try self.file.writeAtAll(frame, offset);
    }

    /// Encode with a stack-backed list when the record fits; fall back to the
    /// heap for large payloads. Keeps the common OLTP append path allocation-free
    /// before the durability round.
    fn appendEncoded(self: *Wal, ctx: anytype) !void {
        const EncodeFn = fn (@TypeOf(ctx), *std.ArrayList(u8), Allocator) anyerror!void;
        const encode: EncodeFn = @TypeOf(ctx).encode;

        var stack: [small_frame_cap - frame_header_len]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&stack);
        var stack_list: std.ArrayList(u8) = .empty;
        encode(ctx, &stack_list, fba.allocator()) catch |err| switch (err) {
            error.OutOfMemory => {
                var list: std.ArrayList(u8) = .empty;
                defer list.deinit(self.gpa);
                try encode(ctx, &list, self.gpa);
                try self.appendPayload(list.items);
                return;
            },
            else => return err,
        };
        try self.appendPayload(stack_list.items);
    }

    fn appendPayload(self: *Wal, payload: []const u8) !void {
        if (self.unusable) return error.WalUnusable;
        if (payload.len == 0 or payload.len > frame_payload_len_max) return error.InvalidWal;

        // One positional write for the whole frame so a crash yields either a
        // complete frame or a single torn tail — never a header without body
        // from two separate writes.
        const frame_len = frame_header_len + payload.len;
        var stack_frame: [small_frame_cap]u8 = undefined;
        const use_stack = frame_len <= small_frame_cap;
        const frame = if (use_stack) stack_frame[0..frame_len] else try self.gpa.alloc(u8, frame_len);
        defer if (!use_stack) self.gpa.free(frame);

        const payload_len: u32 = @intCast(payload.len);
        bytes.writeU32LE(frame[0..4], payload_len);
        bytes.writeU32LE(frame[4..8], frameChecksum(payload_len, payload));
        @memcpy(frame[frame_header_len..], payload);

        const end_offset = blk: {
            try self.append_mutex.lock(self.io);
            defer self.append_mutex.unlock(self.io);

            try self.file.writeAtAll(frame, self.offset);
            self.offset += frame_len;
            break :blk self.offset;
        };
        if (self.sync_on_append) {
            try self.syncThrough(end_offset);
        }
    }

    /// Join or lead a group-commit round. A leader may need more than one
    /// data-sync if new appenders arrive while its first sync is in flight;
    /// no caller returns until its own end offset is covered.
    fn syncThrough(self: *Wal, end_offset: u64) !void {
        try self.sync_mutex.lock(self.io);
        defer self.sync_mutex.unlock(self.io);

        if (self.sync_failed) return error.InputOutput;
        // A concurrent leader may already have covered this offset.
        if (self.durable_offset >= end_offset) return;

        self.requested_durable_offset = @max(self.requested_durable_offset, end_offset);
        if (self.sync_in_progress) {
            while (!self.sync_failed and self.durable_offset < end_offset) {
                try self.sync_cond.wait(self.io, &self.sync_mutex);
            }
            if (self.sync_failed) return error.InputOutput;
            return;
        }

        self.sync_in_progress = true;
        while (self.durable_offset < self.requested_durable_offset) {
            const target_offset = self.requested_durable_offset;
            self.sync_mutex.unlock(self.io);
            self.file.syncData() catch |err| {
                self.sync_mutex.lockUncancelable(self.io);
                self.sync_failed = true;
                self.sync_in_progress = false;
                self.sync_cond.broadcast(self.io);
                return err;
            };
            self.sync_mutex.lockUncancelable(self.io);
            self.sync_rounds += 1;
            self.durable_offset = target_offset;
        }
        self.sync_in_progress = false;
        self.sync_cond.broadcast(self.io);
    }

    /// Persist a recovered logical EOF. Required after torn-tail truncation so a
    /// later append cannot leave garbage past the new end if size metadata was
    /// not durable.
    fn persistEnd(self: *Wal) !void {
        try self.file.syncData();
    }

    /// Begin a checkpoint: stage a replacement WAL off-name.
    ///
    /// The caller emits records describing current committed state, then calls
    /// `Rewrite.commit` to publish. Holding `append_mutex` for the whole rewrite
    /// is what makes the staged file a complete description of committed state:
    /// no frame can be appended to the old file after the caller has read the
    /// state it encodes.
    ///
    /// Crash matrix: the staged file is unnamed until `commit` performs a rename
    /// plus directory sync, so recovery observes either the old WAL (full
    /// history) or the new one (compacted). There is no third state, and hence
    /// no checkpoint sequence number to reconcile.
    pub fn beginRewrite(self: *Wal) !Rewrite {
        if (self.unusable) return error.WalUnusable;
        try self.append_mutex.lock(self.io);
        errdefer self.append_mutex.unlock(self.io);

        var staged = try self.vfs.createAtomicFile("wal");
        errdefer staged.deinit();

        var header: [file_header_len]u8 = undefined;
        encodeFileHeader(&header);
        try staged.writeAtAll(&header, 0);

        return .{
            .wal = self,
            .staged = staged,
            .offset = file_header_len,
            .replaced_bytes = self.offset,
        };
    }

    /// A replacement WAL under construction. Holds `append_mutex` for its whole
    /// lifetime; `commit` or `abort` releases it.
    pub const Rewrite = struct {
        wal: *Wal,
        staged: vfs_mod.AtomicFile,
        offset: u64,
        /// Live WAL size when the rewrite began, sampled under `append_mutex` so
        /// a caller reporting reclaimed bytes cannot race a concurrent append.
        replaced_bytes: u64,

        pub fn emitCreateTable(self: *Rewrite, rec: CreateTableRecord) !void {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(self.wal.gpa);
            try encodeCreateTable(&list, self.wal.gpa, rec);
            try self.emitPayload(list.items);
        }

        pub fn emitInsert(self: *Rewrite, rec: InsertRecord) !void {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(self.wal.gpa);
            try encodeInsert(&list, self.wal.gpa, rec);
            try self.emitPayload(list.items);
        }

        pub fn emitSetSerial(self: *Rewrite, rec: SetSerialRecord) !void {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(self.wal.gpa);
            try encodeSetSerial(&list, self.wal.gpa, rec);
            try self.emitPayload(list.items);
        }

        pub fn emitObserve(self: *Rewrite, rec: ObserveRecord) !void {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(self.wal.gpa);
            try encodeObserve(&list, self.wal.gpa, rec);
            try self.emitPayload(list.items);
        }

        /// Emit the published commit watermark last, so recovery restores it
        /// after the reconstruction records collapse per-commit history.
        pub fn emitSetCommitSeq(self: *Rewrite, commit_seq: u64) !void {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(self.wal.gpa);
            try list.append(self.wal.gpa, @intFromEnum(RecordType.set_commit_seq));
            try writeU64(&list, self.wal.gpa, commit_seq);
            try self.emitPayload(list.items);
        }

        fn emitPayload(self: *Rewrite, payload: []const u8) !void {
            if (payload.len == 0 or payload.len > frame_payload_len_max) return error.InvalidWal;

            const frame_len = frame_header_len + payload.len;
            var stack_frame: [small_frame_cap]u8 = undefined;
            const use_stack = frame_len <= small_frame_cap;
            const frame = if (use_stack) stack_frame[0..frame_len] else try self.wal.gpa.alloc(u8, frame_len);
            defer if (!use_stack) self.wal.gpa.free(frame);

            const payload_len: u32 = @intCast(payload.len);
            bytes.writeU32LE(frame[0..4], payload_len);
            bytes.writeU32LE(frame[4..8], frameChecksum(payload_len, payload));
            @memcpy(frame[frame_header_len..], payload);

            try self.staged.writeAtAll(frame, self.offset);
            self.offset += frame_len;
        }

        /// Publish the staged WAL and adopt it as the live file.
        ///
        /// The staged file is synced before the rename so the published name can
        /// never reference a partially written file. This sync is unconditional:
        /// a relaxed durability level may leave recent appends unsynced in the
        /// old file, and discarding that file makes the staged copy the only
        /// evidence of those commits.
        /// Fully self-cleaning: on any failure the staged file is released and
        /// `append_mutex` is unlocked, so a caller must not also call `abort`.
        pub fn commit(self: *Rewrite) !void {
            defer self.wal.append_mutex.unlock(self.wal.io);

            {
                // Until `staged.commit` returns, the live WAL is still the old
                // file and remains a complete recovery source; releasing the
                // staged file here simply discards the attempt.
                errdefer self.staged.deinit();
                try self.staged.sync();
                try self.staged.commit();
            }
            self.staged.deinit();

            // The old handle now refers to an unlinked inode. Reopen by name and
            // rebase the durability counters onto the new file's offsets, which
            // are unrelated to the old file's.
            self.wal.adoptRewrittenFile(self.offset) catch |err| {
                // The new file is already published, so the data directory is
                // consistent and will recover; this process just no longer holds
                // a usable handle to it.
                self.wal.unusable = true;
                return err;
            };
        }

        /// Discard the staged file and leave the live WAL untouched.
        pub fn abort(self: *Rewrite) void {
            self.staged.deinit();
            self.wal.append_mutex.unlock(self.wal.io);
        }
    };

    /// Swap in the freshly published WAL file. Caller holds `append_mutex`.
    fn adoptRewrittenFile(self: *Wal, new_end: u64) !void {
        // An append that returned before its group-commit round finished can
        // still have a sync in flight against the old handle. Let it drain
        // first: otherwise it would publish a `durable_offset` measured in the
        // old file's offsets, which do not describe the new file.
        try self.sync_mutex.lock(self.io);
        while (self.sync_in_progress) {
            self.sync_cond.wait(self.io, &self.sync_mutex) catch break;
        }
        defer self.sync_mutex.unlock(self.io);

        // Open before closing: if the reopen fails the live handle is still the
        // (now unlinked) old file, which keeps reads and error reporting working
        // instead of leaving `self.file` undefined.
        const reopened = try self.vfs.openFile("wal", .{});
        self.file.close();
        self.file = reopened;
        self.offset = new_end;
        self.file_version = format_version;
        self.durable_offset = new_end;
        self.requested_durable_offset = new_end;
        // The staged file was synced before publication, so the new file is
        // durable through `new_end` regardless of the previous failure state.
        self.sync_failed = false;
    }
};

fn encodeFileHeader(out: *[file_header_len]u8) void {
    @memcpy(out[0..file_magic.len], file_magic);
    bytes.writeU32LE(out[file_magic.len..][0..4], format_version);
}

/// Payload encoders shared by `Wal.append*` and `Rewrite.emit*`. They produce the
/// record body only (type byte first, no frame header) so both paths agree on the
/// on-disk record layout by construction rather than by parallel maintenance.
fn encodeCreateTable(list: *std.ArrayList(u8), gpa: Allocator, rec: CreateTableRecord) !void {
    try list.append(gpa, @intFromEnum(RecordType.create_table));
    try writeStr(list, gpa, rec.name);
    try writeU16(list, gpa, @intCast(rec.columns.len));
    for (rec.columns) |col| {
        try writeColumn(list, gpa, col);
    }
}

fn encodeInsert(list: *std.ArrayList(u8), gpa: Allocator, rec: InsertRecord) !void {
    try list.append(gpa, @intFromEnum(RecordType.insert));
    try writeStr(list, gpa, rec.table);
    try writeU16(list, gpa, @intCast(rec.values.len));
    for (rec.values) |v| try writeValue(list, gpa, v);
}

fn encodeSetSerial(list: *std.ArrayList(u8), gpa: Allocator, rec: SetSerialRecord) !void {
    try list.append(gpa, @intFromEnum(RecordType.set_serial));
    try writeStr(list, gpa, rec.table);
    var b: [8]u8 = undefined;
    bytes.writeI64LE(&b, rec.next_serial);
    try list.appendSlice(gpa, &b);
}

fn encodeObserve(list: *std.ArrayList(u8), gpa: Allocator, rec: ObserveRecord) !void {
    try evidence.validateMetadata(rec);
    try list.append(gpa, @intFromEnum(RecordType.observe));
    try writeU64(list, gpa, rec.evidence_id);
    try writeStr(list, gpa, rec.object_id);
    try list.append(gpa, @intFromEnum(rec.modality));
    try writeStr(list, gpa, rec.media_type);
    try writeStr(list, gpa, rec.observed_at);
    try writeStr(list, gpa, rec.origin);
    try writeStr(list, gpa, rec.owner);
    try writeU64(list, gpa, rec.payload_length);
    try list.appendSlice(gpa, &rec.payload_digest);
}

fn frameChecksum(payload_len: u32, payload: []const u8) u32 {
    var len_bytes: [4]u8 = undefined;
    bytes.writeU32LE(&len_bytes, payload_len);
    var c = std.hash.Crc32.init();
    c.update(&len_bytes);
    c.update(payload);
    return c.final();
}

fn validateFileHeader(file: *vfs_mod.File, len: u64) !u32 {
    if (len < file_header_len) return error.InvalidWal;

    var header: [file_header_len]u8 = undefined;
    const read_len = try file.readAt(&header, 0);
    if (read_len < file_header_len) return error.InvalidWal;
    if (!std.mem.eql(u8, header[0..file_magic.len], file_magic)) return error.UnsupportedWalFormat;
    const version = bytes.readU32LE(header[file_magic.len..][0..4]);
    if (version < format_version_min or version > format_version) {
        return error.UnsupportedWalFormat;
    }
    return version;
}

pub const RecordView = union(RecordType) {
    create_table: struct {
        name: []const u8,
        columns: []ParsedColumn,
    },
    insert: struct {
        table: []const u8,
        values: []value.Value,
    },
    update: struct {
        table: []const u8,
        pk: value.Value,
        values: []value.Value,
    },
    delete: struct {
        table: []const u8,
        pk: value.Value,
    },
    add_column: struct { table: []const u8, column: ParsedColumn },
    drop_column: struct { table: []const u8, column: []const u8 },
    set_default: struct { table: []const u8, column: []const u8, default_expr: value.DefaultExpr },
    set_not_null: struct { table: []const u8, column: []const u8, enabled: bool },
    /// Body is `commit_seq:u64` then `n_ops:u16` then repeated `op_len:u32` +
    /// single-op payload (incl. type byte). Borrowed from the frame buffer for
    /// the duration of `apply` only.
    txn_batch: struct {
        commit_seq: u64,
        body: []const u8,
    },
    set_serial: struct { table: []const u8, next_serial: i64 },
    observe: evidence.Metadata,
    set_commit_seq: u64,

    pub const ParsedColumn = struct {
        name: []const u8,
        type_tag: value.TypeTag,
        primary_key: bool,
        not_null: bool = false,
        unique: bool = false,
        serial: bool = false,
        default_expr: value.DefaultExpr = .none,
    };

    pub fn parseAlloc(gpa: Allocator, payload: []const u8) !struct { view: RecordView, owned: Owned } {
        return parseAllocVersioned(gpa, payload, format_version);
    }

    /// Parse one record body. `file_version` gates format changes: the v5
    /// `txn_batch` body begins with `commit_seq`, older bodies do not.
    pub fn parseAllocVersioned(gpa: Allocator, payload: []const u8, file_version: u32) !struct { view: RecordView, owned: Owned } {
        var owned: Owned = .{ .gpa = gpa, .columns = .empty, .values = .empty, .pk = .null };
        errdefer owned.deinit();

        if (payload.len < 1) return error.InvalidWal;
        const tag = std.enums.fromInt(RecordType, payload[0]) orelse return error.InvalidWal;
        var i: usize = 1;
        switch (tag) {            .create_table => {
                const name = try readStr(payload, &i);
                const ncol = try readU16(payload, &i);
                try owned.columns.ensureTotalCapacity(gpa, ncol);
                var c: u16 = 0;
                while (c < ncol) : (c += 1) {
                    const cname = try readStr(payload, &i);
                    if (i >= payload.len) return error.InvalidWal;
                    const tt = std.enums.fromInt(value.TypeTag, payload[i]) orelse return error.InvalidWal;
                    i += 1;
                    if (i >= payload.len) return error.InvalidWal;
                    const flags = payload[i];
                    i += 1;
                    if (i >= payload.len) return error.InvalidWal;
                    const def_tag = payload[i];
                    i += 1;
                    var def: value.DefaultExpr = .none;
                    switch (def_tag) {
                        0 => {},
                        1 => def = .now,
                        2 => {
                            const lit = try readValue(gpa, payload, &i);
                            def = .{ .literal = lit };
                        },
                        else => return error.InvalidWal,
                    }
                    try owned.columns.append(gpa, .{
                        .name = cname,
                        .type_tag = tt,
                        .primary_key = flags & 1 != 0,
                        .not_null = flags & 2 != 0,
                        .unique = flags & 4 != 0,
                        .serial = flags & 8 != 0,
                        .default_expr = def,
                    });
                }
                return .{
                    .view = .{ .create_table = .{
                        .name = name,
                        .columns = owned.columns.items,
                    } },
                    .owned = owned,
                };
            },
            .insert => {
                const table = try readStr(payload, &i);
                const nval = try readU16(payload, &i);
                try owned.values.ensureTotalCapacity(gpa, nval);
                var v: u16 = 0;
                while (v < nval) : (v += 1) {
                    const val = try readValue(gpa, payload, &i);
                    try owned.values.append(gpa, val);
                }
                return .{
                    .view = .{ .insert = .{
                        .table = table,
                        .values = owned.values.items,
                    } },
                    .owned = owned,
                };
            },
            .update => {
                const table = try readStr(payload, &i);
                owned.pk = try readValue(gpa, payload, &i);
                const nval = try readU16(payload, &i);
                try owned.values.ensureTotalCapacity(gpa, nval);
                var v: u16 = 0;
                while (v < nval) : (v += 1) {
                    const val = try readValue(gpa, payload, &i);
                    try owned.values.append(gpa, val);
                }
                return .{
                    .view = .{ .update = .{
                        .table = table,
                        .pk = owned.pk,
                        .values = owned.values.items,
                    } },
                    .owned = owned,
                };
            },
            .delete => {
                const table = try readStr(payload, &i);
                owned.pk = try readValue(gpa, payload, &i);
                return .{
                    .view = .{ .delete = .{
                        .table = table,
                        .pk = owned.pk,
                    } },
                    .owned = owned,
                };
            },
            .add_column => {
                const table = try readStr(payload, &i);
                const column = try readColumn(gpa, payload, &i);
                try owned.columns.append(gpa, column);
                return .{ .view = .{ .add_column = .{ .table = table, .column = owned.columns.items[0] } }, .owned = owned };
            },
            .drop_column => {
                const table = try readStr(payload, &i);
                const column = try readStr(payload, &i);
                return .{ .view = .{ .drop_column = .{ .table = table, .column = column } }, .owned = owned };
            },
            .set_default => {
                const table = try readStr(payload, &i);
                const column = try readStr(payload, &i);
                const default_expr = try readDefault(gpa, payload, &i);
                if (default_expr == .literal) try owned.values.append(gpa, default_expr.literal);
                return .{ .view = .{ .set_default = .{ .table = table, .column = column, .default_expr = default_expr } }, .owned = owned };
            },
            .set_not_null => {
                const table = try readStr(payload, &i);
                const column = try readStr(payload, &i);
                if (i >= payload.len) return error.InvalidWal;
                const enabled = payload[i] != 0;
                return .{ .view = .{ .set_not_null = .{ .table = table, .column = column, .enabled = enabled } }, .owned = owned };
            },
            .set_serial => {
                const table = try readStr(payload, &i);
                if (i + 8 > payload.len) return error.InvalidWal;
                const next_serial = bytes.readI64LE(payload[i..][0..8]);
                i += 8;
                if (i != payload.len) return error.InvalidWal;
                return .{ .view = .{ .set_serial = .{ .table = table, .next_serial = next_serial } }, .owned = owned };
            },
            .observe => {
                const evidence_id = try readU64(payload, &i);
                const object_id = try readStr(payload, &i);
                if (i >= payload.len) return error.InvalidWal;
                const modality = std.enums.fromInt(evidence.Modality, payload[i]) orelse return error.InvalidWal;
                i += 1;
                const media_type = try readStr(payload, &i);
                const observed_at = try readStr(payload, &i);
                const origin = try readStr(payload, &i);
                const owner = try readStr(payload, &i);
                const payload_length = try readU64(payload, &i);
                if (payload.len -| i < evidence.DIGEST_LENGTH) return error.InvalidWal;
                var payload_digest: [evidence.DIGEST_LENGTH]u8 = undefined;
                @memcpy(&payload_digest, payload[i..][0..evidence.DIGEST_LENGTH]);
                i += evidence.DIGEST_LENGTH;
                if (i != payload.len) return error.InvalidWal;
                const metadata: evidence.Metadata = .{
                    .evidence_id = evidence_id,
                    .object_id = object_id,
                    .modality = modality,
                    .media_type = media_type,
                    .observed_at = observed_at,
                    .origin = origin,
                    .owner = owner,
                    .payload_length = payload_length,
                    .payload_digest = payload_digest,
                };
                try evidence.validateMetadata(metadata);
                return .{ .view = .{ .observe = metadata }, .owned = owned };
            },
            .txn_batch => {
                // Validate shape eagerly; engine expands nested ops during apply.
                var j: usize = i;
                var commit_seq: u64 = 0;
                if (file_version >= 5) {
                    commit_seq = try readU64(payload, &j);
                }
                const n_ops = try readU16(payload, &j);
                if (n_ops == 0) return error.InvalidWal;
                var k: u16 = 0;
                while (k < n_ops) : (k += 1) {
                    const op_len = try readU32(payload, &j);
                    if (op_len == 0 or j + op_len > payload.len) return error.InvalidWal;
                    const sub = payload[j .. j + op_len];
                    j += op_len;
                    // Nested batches are forbidden; each sub-op must be a plain record.
                    if (sub.len < 1) return error.InvalidWal;
                    const sub_tag = std.enums.fromInt(RecordType, sub[0]) orelse return error.InvalidWal;
                    if (sub_tag == .txn_batch) return error.InvalidWal;
                    var sub_parsed = try parseAllocVersioned(gpa, sub, file_version);
                    sub_parsed.owned.deinit();
                }
                if (j != payload.len) return error.InvalidWal;
                return .{ .view = .{ .txn_batch = .{ .commit_seq = commit_seq, .body = payload[i..] } }, .owned = owned };
            },
            .set_commit_seq => {
                if (payload.len - i != 8) return error.InvalidWal;
                const commit_seq = readU64(payload, &i) catch return error.InvalidWal;
                return .{ .view = .{ .set_commit_seq = commit_seq }, .owned = owned };
            },
        }
    }

    pub const Owned = struct {
        gpa: Allocator,
        columns: std.ArrayList(ParsedColumn),
        values: std.ArrayList(value.Value),
        pk: value.Value,

        pub fn deinit(self: *Owned) void {
            for (self.values.items) |*v| v.deinit(self.gpa);
            for (self.columns.items) |*c| c.default_expr.deinit(self.gpa);
            self.columns.deinit(self.gpa);
            self.values.deinit(self.gpa);
            self.pk.deinit(self.gpa);
        }
    };
};

/// Replay complete, checksummed frames; truncate only a torn tail.
///
/// Invariants (see docs/ARCHITECTURE.md):
/// - Only complete, supported, checksum-valid frames are applied.
/// - An incomplete final frame (short header, or declared body past EOF) is
///   truncated and the new EOF is synced — never guessed or repaired mid-file.
/// - A complete frame with a bad checksum, zero/oversized length, or undecodable
///   payload fails recovery; the file is left untouched for forensics.
pub fn replayWal(self: *Wal, ctx: anytype, comptime apply: fn (@TypeOf(ctx), RecordView) anyerror!void) !void {
    _ = try validateFileHeader(&self.file, self.offset);
    var off: u64 = file_header_len;
    var truncated = false;
    while (off < self.offset) {
        if (self.offset - off < frame_header_len) {
            try self.file.truncate(off);
            self.offset = off;
            truncated = true;
            break;
        }

        var header: [frame_header_len]u8 = undefined;
        const header_len = try self.file.readAt(&header, off);
        if (header_len < frame_header_len) return error.InvalidWal;
        const payload_len = bytes.readU32LE(header[0..4]);
        const payload_crc = bytes.readU32LE(header[4..8]);
        // Zero or absurd lengths on a fully present header are corruption, not a
        // torn tail: a real append never writes a zero-length payload.
        if (payload_len == 0 or payload_len > frame_payload_len_max) return error.CorruptWal;
        const frame_len: u64 = frame_header_len + payload_len;
        if (frame_len > self.offset - off) {
            try self.file.truncate(off);
            self.offset = off;
            truncated = true;
            break;
        }

        const buf = try self.gpa.alloc(u8, payload_len);
        defer self.gpa.free(buf);
        const payload_off = off + frame_header_len;
        const payload_read_len = try self.file.readAt(buf, payload_off);
        if (payload_read_len < payload_len) return error.InvalidWal;
        if (frameChecksum(payload_len, buf) != payload_crc) return error.CorruptWal;

        var parsed = try RecordView.parseAllocVersioned(self.gpa, buf, self.file_version);
        defer parsed.owned.deinit();
        try apply(ctx, parsed.view);
        off += frame_len;
    }
    if (truncated) {
        try self.persistEnd();
        // `open` initializes these to the physical file length. After removing
        // a torn tail, the synced logical EOF is the only durable boundary.
        // Leaving the old value here could let the next synchronous append
        // incorrectly conclude that its new frame was already durable.
        self.durable_offset = self.offset;
        self.requested_durable_offset = self.offset;
    }
}

fn writeU16(list: *std.ArrayList(u8), gpa: Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    bytes.writeU16LE(&b, v);
    try list.appendSlice(gpa, &b);
}

fn writeU32(list: *std.ArrayList(u8), gpa: Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    bytes.writeU32LE(&b, v);
    try list.appendSlice(gpa, &b);
}

fn writeU64(list: *std.ArrayList(u8), gpa: Allocator, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

fn encodeTxnOp(list: *std.ArrayList(u8), gpa: Allocator, op: TxnOp) !void {
    switch (op) {
        .insert => |rec| {
            try list.append(gpa, @intFromEnum(RecordType.insert));
            try writeStr(list, gpa, rec.table);
            try writeU16(list, gpa, @intCast(rec.values.len));
            for (rec.values) |v| try writeValue(list, gpa, v);
        },
        .update => |rec| {
            try list.append(gpa, @intFromEnum(RecordType.update));
            try writeStr(list, gpa, rec.table);
            try writeValue(list, gpa, rec.pk);
            try writeU16(list, gpa, @intCast(rec.values.len));
            for (rec.values) |v| try writeValue(list, gpa, v);
        },
        .delete => |rec| {
            try list.append(gpa, @intFromEnum(RecordType.delete));
            try writeStr(list, gpa, rec.table);
            try writeValue(list, gpa, rec.pk);
        },
    }
}

fn readU32(payload: []const u8, i: *usize) !u32 {
    if (i.* + 4 > payload.len) return error.InvalidWal;
    const v = bytes.readU32LE(payload[i.*..][0..4]);
    i.* += 4;
    return v;
}

fn readU64(payload: []const u8, i: *usize) !u64 {
    if (i.* + 8 > payload.len) return error.InvalidWal;
    const value_read = std.mem.readInt(u64, payload[i.*..][0..8], .little);
    i.* += 8;
    return value_read;
}

/// Iterate nested ops inside a `txn_batch` body. `body` excludes the type byte;
/// for format v5 it is `commit_seq:u64` then `n_ops:u16` then repeated ops.
pub fn forEachTxnBatchOp(
    gpa: Allocator,
    body: []const u8,
    file_version: u32,
    ctx: anytype,
    comptime apply: fn (@TypeOf(ctx), RecordView) anyerror!void,
) !void {
    var i: usize = 0;
    if (file_version >= 5) {
        _ = try readU64(body, &i);
    }
    const n_ops = try readU16(body, &i);
    var k: u16 = 0;
    while (k < n_ops) : (k += 1) {
        const op_len = try readU32(body, &i);
        if (op_len == 0 or i + op_len > body.len) return error.InvalidWal;
        const sub = body[i .. i + op_len];
        i += op_len;
        var parsed = try RecordView.parseAllocVersioned(gpa, sub, file_version);
        defer parsed.owned.deinit();
        try apply(ctx, parsed.view);
    }
    if (i != body.len) return error.InvalidWal;
}

fn writeStr(list: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    if (s.len > std.math.maxInt(u16)) return error.NameTooLong;
    try writeU16(list, gpa, @intCast(s.len));
    try list.appendSlice(gpa, s);
}

fn writeValue(list: *std.ArrayList(u8), gpa: Allocator, v: value.Value) !void {
    switch (v) {
        .null => try list.append(gpa, 0),
        .int => |i| {
            try list.append(gpa, 1);
            var b: [8]u8 = undefined;
            bytes.writeI64LE(&b, i);
            try list.appendSlice(gpa, &b);
        },
        .text => |t| {
            try list.append(gpa, 2);
            try writeStr(list, gpa, t);
        },
        .bool => |b| {
            try list.append(gpa, 3);
            try list.append(gpa, if (b) 1 else 0);
        },
        .vector => |items| {
            value.validateVector(items) catch return error.InvalidWal;
            if (items.len > std.math.maxInt(u16)) return error.NameTooLong;
            try list.append(gpa, 4);
            try writeU16(list, gpa, @intCast(items.len));
            for (items) |item| {
                var bytes_out: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes_out, @bitCast(item), .little);
                try list.appendSlice(gpa, &bytes_out);
            }
        },
    }
}

fn writeDefault(list: *std.ArrayList(u8), gpa: Allocator, default_expr: value.DefaultExpr) !void {
    switch (default_expr) {
        .none => try list.append(gpa, 0),
        .now => try list.append(gpa, 1),
        .literal => |v| {
            try list.append(gpa, 2);
            try writeValue(list, gpa, v);
        },
    }
}

fn writeColumn(list: *std.ArrayList(u8), gpa: Allocator, col: value.Column) !void {
    try writeStr(list, gpa, col.name);
    try list.append(gpa, @intFromEnum(col.type_tag));
    var flags: u8 = 0;
    if (col.primary_key) flags |= 1;
    if (col.not_null) flags |= 2;
    if (col.unique) flags |= 4;
    if (col.serial) flags |= 8;
    try list.append(gpa, flags);
    try writeDefault(list, gpa, col.default_expr);
}

fn readU16(payload: []const u8, i: *usize) !u16 {
    if (i.* + 2 > payload.len) return error.InvalidWal;
    const v = bytes.readU16LE(payload[i.*..][0..2]);
    i.* += 2;
    return v;
}

fn readStr(payload: []const u8, i: *usize) ![]const u8 {
    const len = try readU16(payload, i);
    if (i.* + len > payload.len) return error.InvalidWal;
    const s = payload[i.* .. i.* + len];
    i.* += len;
    return s;
}

fn readValue(gpa: Allocator, payload: []const u8, i: *usize) !value.Value {
    if (i.* >= payload.len) return error.InvalidWal;
    const tag = payload[i.*];
    i.* += 1;
    switch (tag) {
        0 => return .null,
        1 => {
            if (i.* + 8 > payload.len) return error.InvalidWal;
            const v = bytes.readI64LE(payload[i.*..][0..8]);
            i.* += 8;
            return .{ .int = v };
        },
        2 => {
            const s = try readStr(payload, i);
            return .{ .text = try gpa.dupe(u8, s) };
        },
        3 => {
            if (i.* >= payload.len) return error.InvalidWal;
            const b = payload[i.*] != 0;
            i.* += 1;
            return .{ .bool = b };
        },
        4 => {
            const count = try readU16(payload, i);
            if (count == 0 or payload.len - i.* < @as(usize, count) * 4) return error.InvalidWal;
            const items = try gpa.alloc(f32, count);
            errdefer gpa.free(items);
            for (items) |*item| {
                item.* = @bitCast(std.mem.readInt(u32, payload[i.*..][0..4], .little));
                i.* += 4;
            }
            try value.validateVector(items);
            return .{ .vector = items };
        },
        else => return error.InvalidWal,
    }
}

fn readDefault(gpa: Allocator, payload: []const u8, i: *usize) !value.DefaultExpr {
    if (i.* >= payload.len) return error.InvalidWal;
    const tag = payload[i.*];
    i.* += 1;
    return switch (tag) {
        0 => .none,
        1 => .now,
        2 => .{ .literal = try readValue(gpa, payload, i) },
        else => error.InvalidWal,
    };
}

fn readColumn(gpa: Allocator, payload: []const u8, i: *usize) !RecordView.ParsedColumn {
    const name = try readStr(payload, i);
    if (i.* + 2 > payload.len) return error.InvalidWal;
    const type_tag = std.enums.fromInt(value.TypeTag, payload[i.*]) orelse return error.InvalidWal;
    i.* += 1;
    const flags = payload[i.*];
    i.* += 1;
    return .{
        .name = name,
        .type_tag = type_tag,
        .primary_key = flags & 1 != 0,
        .not_null = flags & 2 != 0,
        .unique = flags & 4 != 0,
        .serial = flags & 8 != 0,
        .default_expr = try readDefault(gpa, payload, i),
    };
}

const TestSink = struct {
    inserts: u32 = 0,

    fn apply(self: *TestSink, view: RecordView) !void {
        switch (view) {
            .insert => self.inserts += 1,
            else => {},
        }
    }
};

const ConcurrentSink = struct {
    inserts: u32 = 0,
    seen: [256]bool = [_]bool{false} ** 256,

    fn apply(self: *ConcurrentSink, view: RecordView) !void {
        switch (view) {
            .insert => |insert| {
                if (insert.values.len != 1) return error.InvalidWal;
                const id = switch (insert.values[0]) {
                    .int => |v| std.math.cast(usize, v) orelse return error.InvalidWal,
                    else => return error.InvalidWal,
                };
                if (id >= self.seen.len or self.seen[id]) return error.InvalidWal;
                self.seen[id] = true;
                self.inserts += 1;
            },
            else => return error.InvalidWal,
        }
    }
};

fn noopApply(_: void, _: RecordView) !void {}

const ConcurrentAppend = struct {
    wal: *Wal,
    start: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    first_id: u32,
    count: u32,

    fn run(self: ConcurrentAppend) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        for (0..self.count) |i| {
            self.wal.appendInsert(.{
                .table = "concurrent",
                .values = &.{.{ .int = @intCast(self.first_id + i) }},
            }) catch {
                self.failed.store(true, .release);
                return;
            };
        }
    }
};

fn openCleanDir(comptime name: []const u8) ![]const u8 {
    const io = std.testing.io;
    Io.Dir.cwd().deleteTree(io, name) catch {};
    return name;
}

fn removeDir(name: []const u8) void {
    Io.Dir.cwd().deleteTree(std.testing.io, name) catch {};
}

test "synchronous concurrent append group recovers every successful frame" {
    const gpa = std.heap.page_allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-group-commit");
    defer removeDir(dir_name);

    const workers = 8;
    const writes_per_worker = 32;
    const total_writes = workers * writes_per_worker;
    var start = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var threads: [workers]std.Thread = undefined;
    var sync_rounds: u64 = 0;

    {
        var wal = try Wal.open(gpa, io, dir_name, true);
        defer wal.deinit();

        for (&threads, 0..) |*thread, worker| {
            thread.* = try std.Thread.spawn(.{}, ConcurrentAppend.run, .{ConcurrentAppend{
                .wal = &wal,
                .start = &start,
                .failed = &failed,
                .first_id = @intCast(worker * writes_per_worker),
                .count = writes_per_worker,
            }});
        }
        start.store(true, .release);
        for (&threads) |thread| thread.join();
        try std.testing.expect(!failed.load(.acquire));
        sync_rounds = wal.sync_rounds;
        // Concurrent appenders must share durability rounds; otherwise group
        // commit is not engaging and each frame pays a full fdatasync.
        try std.testing.expect(sync_rounds < total_writes);
        try std.testing.expect(sync_rounds > 0);
    }

    var wal = try Wal.open(gpa, io, dir_name, false);
    defer wal.deinit();
    var sink: ConcurrentSink = .{};
    try replayWal(&wal, &sink, ConcurrentSink.apply);
    try std.testing.expectEqual(@as(u32, total_writes), sink.inserts);
    for (sink.seen) |present| try std.testing.expect(present);
}

test "wal rejects a complete frame with a bad checksum" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-checksum");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 1 }} });

        var corrupt: [1]u8 = .{0};
        try wal.file.writeAtAll(&corrupt, file_header_len + frame_header_len);
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try std.testing.expectError(error.CorruptWal, replayWal(&wal, {}, noopApply));
    }
}

test "wal truncates a torn tail and keeps the committed prefix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-torn");
    defer removeDir(dir_name);

    var prefix_end: u64 = 0;
    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 1 }} });
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 2 }} });
        prefix_end = wal.offset;
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 3 }} });

        // Simulate crash after a partial frame write: keep only half of the last frame.
        const torn_len = prefix_end + (wal.offset - prefix_end) / 2;
        try std.testing.expect(torn_len > prefix_end);
        try std.testing.expect(torn_len < wal.offset);
        try wal.file.truncate(torn_len);
        wal.offset = torn_len;
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: TestSink = .{};
        try replayWal(&wal, &sink, TestSink.apply);
        try std.testing.expectEqual(@as(u32, 2), sink.inserts);
        try std.testing.expectEqual(prefix_end, wal.offset);
        try std.testing.expectEqual(prefix_end, try wal.file.size());
    }

    // After sealing the torn tail, new appends must recover cleanly with no garbage tail.
    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: TestSink = .{};
        try replayWal(&wal, &sink, TestSink.apply);
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 4 }} });
    }
    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: TestSink = .{};
        try replayWal(&wal, &sink, TestSink.apply);
        try std.testing.expectEqual(@as(u32, 3), sink.inserts);
    }
}

test "wal truncates a partial frame header at EOF" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-partial-header");
    defer removeDir(dir_name);

    var prefix_end: u64 = 0;
    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 1 }} });
        prefix_end = wal.offset;
        var junk: [3]u8 = .{ 0x01, 0x02, 0x03 };
        try wal.file.writeAtAll(&junk, wal.offset);
        wal.offset += junk.len;
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: TestSink = .{};
        try replayWal(&wal, &sink, TestSink.apply);
        try std.testing.expectEqual(@as(u32, 1), sink.inserts);
        try std.testing.expectEqual(prefix_end, wal.offset);
    }
}

test "wal rejects a flipped length on an otherwise complete frame" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-bad-len");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 1 }} });
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 2 }} });

        // Flip the low bit of the first frame's payload_len. The frame remains
        // fully inside the file, so this must be CorruptWal — not a torn tail.
        var len_byte: [1]u8 = undefined;
        _ = try wal.file.readAt(&len_byte, file_header_len);
        len_byte[0] ^= 1;
        try wal.file.writeAtAll(&len_byte, file_header_len);
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try std.testing.expectError(error.CorruptWal, replayWal(&wal, {}, noopApply));
        // Forensics: refuse without truncating away evidence past the bad frame.
        try std.testing.expect((try wal.file.size()) > file_header_len);
    }
}

// A version-1 file predates `set_serial` and needs no compatibility shim to
// replay: it simply cannot contain the record. Rejecting it would force an
// avoidable data-directory migration, so this build reads it and only upgrades
// the header when a checkpoint rewrites the file.
test "wal replays a version 1 file and a checkpoint upgrades it in place" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-v1");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try wal.appendInsert(.{ .table = "users", .values = &.{.{ .int = 1 }} });
        // Rewrite the header as version 1; the frames are byte-identical.
        var ver: [4]u8 = undefined;
        bytes.writeU32LE(&ver, 1);
        try wal.file.writeAtAll(&ver, file_magic.len);
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: TestSink = .{};
        try replayWal(&wal, &sink, TestSink.apply);
        try std.testing.expectEqual(@as(u32, 1), sink.inserts);

        var rewrite = try wal.beginRewrite();
        try rewrite.emitInsert(.{ .table = "users", .values = &.{.{ .int = 1 }} });
        try rewrite.commit();
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var ver: [4]u8 = undefined;
        _ = try wal.file.readAt(&ver, file_magic.len);
        try std.testing.expectEqual(format_version, bytes.readU32LE(&ver));
    }
}

test "a rewritten wal accepts appends at its own offsets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-rewrite");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, true);
        defer wal.deinit();
        for (0..20) |i| {
            try wal.appendInsert(.{ .table = "t", .values = &.{.{ .int = @intCast(i) }} });
        }
        const before = wal.offset;

        var rewrite = try wal.beginRewrite();
        try rewrite.emitInsert(.{ .table = "t", .values = &.{.{ .int = 99 }} });
        try rewrite.commit();

        // Offsets rebase onto the new file, and durability tracking follows.
        try std.testing.expect(wal.offset < before);
        try std.testing.expectEqual(wal.offset, wal.durable_offset);

        try wal.appendInsert(.{ .table = "t", .values = &.{.{ .int = 100 }} });
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, true);
        defer wal.deinit();
        var sink: TestSink = .{};
        try replayWal(&wal, &sink, TestSink.apply);
        // Only the rewritten record plus the post-checkpoint append.
        try std.testing.expectEqual(@as(u32, 2), sink.inserts);
        try std.testing.expectEqual(wal.offset, wal.durable_offset);
    }
}

test "set_serial survives an encode and replay roundtrip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-set-serial");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try wal.appendSetSerial(.{ .table = "users", .next_serial = 4242 });
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: SerialSink = .{};
        try replayWal(&wal, &sink, SerialSink.apply);
        try std.testing.expectEqual(@as(i64, 4242), sink.seen.?);
    }
}

const SerialSink = struct {
    seen: ?i64 = null,

    fn apply(self: *SerialSink, view: RecordView) !void {
        switch (view) {
            .set_serial => |ss| {
                try std.testing.expectEqualStrings("users", ss.table);
                self.seen = ss.next_serial;
            },
            else => return error.InvalidWal,
        }
    }
};

// A truncated `set_serial` body must be rejected, not read as a short integer.
test "wal rejects a set_serial record with a truncated counter" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-serial-trunc");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();

        // Hand-build a set_serial payload whose declared frame is complete but
        // whose body stops inside the i64. A torn-tail truncation would hide
        // this; a complete frame must fail closed instead.
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        try payload.append(gpa, @intFromEnum(RecordType.set_serial));
        try writeStr(&payload, gpa, "users");
        try payload.appendSlice(gpa, &[_]u8{ 1, 2, 3 });
        try wal.appendPayload(payload.items);
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try std.testing.expectError(error.InvalidWal, replayWal(&wal, {}, noopApply));
    }
}

test "wal rejects unknown magic and format version" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-format");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var bad_magic: [4]u8 = "XXXX".*;
        try wal.file.writeAtAll(&bad_magic, 0);
    }
    try std.testing.expectError(error.UnsupportedWalFormat, Wal.open(gpa, io, dir_name, false));

    removeDir(dir_name);
    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var ver: [4]u8 = undefined;
        bytes.writeU32LE(&ver, format_version + 1);
        try wal.file.writeAtAll(&ver, file_magic.len);
    }
    try std.testing.expectError(error.UnsupportedWalFormat, Wal.open(gpa, io, dir_name, false));
}

// A v5 `txn_batch` carries its commit_seq so recovery can rebuild the watermark.
test "wal replays a v5 txn_batch with its commit seq" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-v5-batch");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        const ops = [_]TxnOp{.{
            .insert = .{ .table = "users", .values = &.{.{ .int = 1 }} },
        }};
        try wal.appendTxnBatch(7, &ops);
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: BatchSink = .{};
        try replayWal(&wal, &sink, BatchSink.apply);
        try std.testing.expectEqual(@as(u64, 7), sink.last_commit_seq);
        try std.testing.expectEqual(@as(u32, 1), sink.inserts);
    }
}

test "wal replays a set_commit_seq record" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-set-commit-seq");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        try wal.appendSetCommitSeq(99);
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: BatchSink = .{};
        try replayWal(&wal, &sink, BatchSink.apply);
        try std.testing.expectEqual(@as(u64, 99), sink.watermark);
    }
}

test "wal appends a group of txn_batch frames as one durable round" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = try openCleanDir("zig-cache/runadb-test-wal-group-batch");
    defer removeDir(dir_name);

    {
        var wal = try Wal.open(gpa, io, dir_name, true);
        defer wal.deinit();
        const ops = [_]TxnOp{.{
            .insert = .{ .table = "users", .values = &.{.{ .int = 1 }} },
        }};
        const batches = [_]Wal.TxnBatchGroup{
            .{ .commit_seq = 1, .ops = &ops },
            .{ .commit_seq = 2, .ops = &ops },
        };
        try wal.appendTxnBatchGroup(&batches);
        // Two commits share one durability round.
        try std.testing.expectEqual(@as(u64, 1), wal.sync_rounds);
    }

    {
        var wal = try Wal.open(gpa, io, dir_name, false);
        defer wal.deinit();
        var sink: BatchSink = .{};
        try replayWal(&wal, &sink, BatchSink.apply);
        try std.testing.expectEqual(@as(u32, 2), sink.inserts);
    }
}

const BatchSink = struct {
    inserts: u32 = 0,
    last_commit_seq: u64 = 0,
    watermark: u64 = 0,

    fn apply(self: *BatchSink, view: RecordView) !void {
        switch (view) {
            .txn_batch => |batch| {
                self.last_commit_seq = batch.commit_seq;
                try forEachTxnBatchOp(std.testing.allocator, batch.body, format_version, self, subApply);
            },
            .set_commit_seq => |seq| self.watermark = seq,
            .insert => |ins| {
                _ = ins;
                self.inserts += 1;
            },
            else => {},
        }
    }
};

fn subApply(self: *BatchSink, view: RecordView) !void {
    switch (view) {
        .insert => |ins| {
            _ = ins;
            self.inserts += 1;
        },
        else => return error.InvalidWal,
    }
}
