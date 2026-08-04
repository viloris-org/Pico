const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const mvcc = @import("mvcc.zig");

/// Errors from in-memory 表 storage: constraints, PK index, and row shape.
/// Engine maps the same set through for WAL-backed calls.
pub const Error = error{
    TableExists,
    TableNotFound,
    ColumnCountMismatch,
    DuplicatePrimaryKey,
    MissingPrimaryKey,
    PrimaryKeyNotFound,
    PrimaryKeyImmutable,
    TypeMismatch,
    InvalidIdentifier,
    NotNullViolation,
    UniqueViolation,
    ColumnExists,
    ColumnNotFound,
    CannotDropPrimaryKey,
};

pub const Row = struct {
    values: []value.Value,
    /// Monotonic per-table version stamp, bumped on every mutation. Used by the
    /// commit coordinator to detect write-write conflicts: an update/delete
    /// records the version it observed, and commit fails if that version no
    /// longer matches the published row.
    version: u64 = 0,
    /// Commit sequence at which this version was created. A version created
    /// after a snapshot watermark is invisible to that snapshot.
    created_seq: u64 = 0,

    pub fn deinit(self: *Row, gpa: Allocator) void {
        for (self.values) |*v| v.deinit(gpa);
        gpa.free(self.values);
    }

    pub fn clone(self: Row, gpa: Allocator) Allocator.Error!Row {
        const vals = try gpa.alloc(value.Value, self.values.len);
        errdefer gpa.free(vals);
        var i: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) vals[j].deinit(gpa);
        }
        while (i < self.values.len) : (i += 1) {
            vals[i] = try self.values[i].clone(gpa);
        }
        return .{ .values = vals, .version = self.version, .created_seq = self.created_seq };
    }
};

/// A superseded row version retained for snapshot reads. Owns a copy of the
/// primary key and values; `created_seq`/`deleted_seq` delimit its visibility
/// interval `[created_seq, deleted_seq)`. `version` is the superseded live
/// row's coordinator version stamp, kept so historical reads expose the same
/// stamp shape as live rows.
pub const RetainedVersion = struct {
    pk: value.Value,
    values: []value.Value,
    created_seq: u64,
    deleted_seq: u64,
    version: u64,

    pub fn deinit(self: *RetainedVersion, gpa: Allocator) void {
        self.pk.deinit(gpa);
        for (self.values) |*v| v.deinit(gpa);
        gpa.free(self.values);
    }
};

/// Column definition input for `Table.create` (borrowed names / defaults).
pub const ColumnSpec = struct {
    name: []const u8,
    type_tag: value.TypeTag,
    primary_key: bool = false,
    not_null: bool = false,
    unique: bool = false,
    serial: bool = false,
    default_expr: value.DefaultExpr = .none,
};

/// In-memory 表: column defs, rows, and primary-key secondary indexes.
/// Does not know about WAL; Engine owns durability ordering.
pub const Table = struct {
    name: []u8,
    columns: []value.Column,
    /// null = heap table without single-column PK (e.g. composite PRIMARY KEY).
    pk_index: ?usize,
    /// INT primary key → row index.
    by_pk_int: std.AutoHashMap(i64, usize),
    /// TEXT primary key → row index (keys owned by row storage).
    by_pk_text: std.StringHashMap(usize),
    rows: std.ArrayList(Row),
    /// Superseded row versions retained for snapshot reads (single-column
    /// primary-key tables only). Heap tables do not address versions by key and
    /// never populate this. Reclaimed by `reclaimRetained` when no active
    /// snapshot can still see them.
    retained: std.ArrayList(RetainedVersion) = .empty,
    /// Next value for SERIAL/BIGSERIAL columns.
    next_serial: i64,
    /// Monotonic version stamp assigned to the next row version. Every
    /// mutation consumes one value so a changed row is always observable as a
    /// different version to the commit coordinator.
    next_version: u64 = 1,

    pub fn deinit(self: *Table, gpa: Allocator) void {
        gpa.free(self.name);
        for (self.columns) |*c| c.deinit(gpa);
        gpa.free(self.columns);
        for (self.rows.items) |*r| r.deinit(gpa);
        self.rows.deinit(gpa);
        self.by_pk_int.deinit();
        self.by_pk_text.deinit();
        for (self.retained.items) |*rv| rv.deinit(gpa);
        self.retained.deinit(gpa);
    }

    pub fn pkIsText(self: *const Table) bool {
        const pki = self.pk_index orelse return false;
        return self.columns[pki].type_tag == .text;
    }

    /// Validate column-level schema rules (not name uniqueness in a catalog).
    pub fn validateSchema(cols: []const ColumnSpec) Error!void {
        if (cols.len == 0) return error.MissingPrimaryKey;

        var primary_key_count: usize = 0;
        for (cols) |col| {
            if (!col.primary_key) continue;
            primary_key_count += 1;
            if (col.type_tag != .int and col.type_tag != .text) return error.TypeMismatch;
        }
        if (primary_key_count > 1) return error.MissingPrimaryKey;
    }

    /// Build an empty table from column specs. Caller registers it in a name map.
    pub fn create(gpa: Allocator, name: []const u8, cols: []const ColumnSpec) (Error || Allocator.Error)!Table {
        try validateSchema(cols);

        var pk_index: ?usize = null;
        const columns = try gpa.alloc(value.Column, cols.len);
        errdefer gpa.free(columns);
        var allocated: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < allocated) : (j += 1) columns[j].deinit(gpa);
        }
        for (cols, 0..) |c, i| {
            columns[i] = .{
                .name = try gpa.dupe(u8, c.name),
                .type_tag = c.type_tag,
                .primary_key = c.primary_key,
                .not_null = c.not_null,
                .unique = c.unique,
                .serial = c.serial,
                .default_expr = try c.default_expr.clone(gpa),
            };
            allocated = i + 1;
            if (c.primary_key) {
                if (pk_index != null) return error.MissingPrimaryKey;
                if (c.type_tag != .int and c.type_tag != .text) return error.TypeMismatch;
                pk_index = i;
            }
        }

        const tname = try gpa.dupe(u8, name);
        errdefer gpa.free(tname);

        return .{
            .name = tname,
            .columns = columns,
            .pk_index = pk_index,
            .by_pk_int = std.AutoHashMap(i64, usize).init(gpa),
            .by_pk_text = std.StringHashMap(usize).init(gpa),
            .rows = .empty,
            .next_serial = 1,
        };
    }

    pub fn pkLookup(self: *const Table, pk: value.Value) ?usize {
        return switch (pk) {
            .int => |i| self.by_pk_int.get(i),
            .text => |t| self.by_pk_text.get(t),
            else => null,
        };
    }

    /// Current version stamp of the live row for `pk`, or null when absent.
    /// Used by the commit coordinator for write-write conflict validation.
    pub fn rowVersion(self: *const Table, pk: value.Value) ?u64 {
        const idx = self.pkLookup(pk) orelse return null;
        return self.rows.items[idx].version;
    }

    pub fn pkContains(self: *const Table, pk: value.Value) bool {
        return self.pkLookup(pk) != null;
    }

    fn pkPut(self: *Table, pk: value.Value, idx: usize) (Error || Allocator.Error)!void {
        switch (pk) {
            .int => |i| try self.by_pk_int.put(i, idx),
            .text => |t| try self.by_pk_text.put(t, idx),
            else => return error.MissingPrimaryKey,
        }
    }

    fn pkRemove(self: *Table, pk: value.Value) void {
        switch (pk) {
            .int => |i| _ = self.by_pk_int.remove(i),
            .text => |t| _ = self.by_pk_text.remove(t),
            else => {},
        }
    }

    fn checkTypes(self: *const Table, values: []const value.Value) Error!void {
        if (values.len != self.columns.len) return error.ColumnCountMismatch;
        for (values, self.columns) |v, col| {
            switch (v) {
                .null => {
                    if (col.not_null and !col.serial) return error.NotNullViolation;
                },
                .int => if (col.type_tag != .int) return error.TypeMismatch,
            .text => if (col.type_tag != .text) return error.TypeMismatch,
            .bool => if (col.type_tag != .bool) return error.TypeMismatch,
            .vector => |items| {
                if (col.type_tag != .vector) return error.TypeMismatch;
                value.validateVector(items) catch return error.TypeMismatch;
            },
        }
        }
    }

    fn checkUnique(self: *const Table, values: []const value.Value, skip_idx: ?usize) Error!void {
        for (self.columns, 0..) |col, ci| {
            // A single-column primary key is checked through `by_pk_*` before
            // this scan. Rechecking it here turns each insert into O(table size).
            if (!col.unique or (self.pk_index != null and ci == self.pk_index.?)) continue;
            const v = values[ci];
            if (v == .null) continue;
            for (self.rows.items, 0..) |row, ri| {
                if (skip_idx) |s| if (s == ri) continue;
                if (value.Value.eql(row.values[ci], v)) return error.UniqueViolation;
            }
        }
    }

    pub fn validateInsert(self: *const Table, values: []const value.Value) Error!void {
        try self.checkTypes(values);
        if (self.pk_index) |pk_index| {
            const pk = values[pk_index];
            switch (pk) {
                .int, .text => {},
                else => return error.MissingPrimaryKey,
            }
            if (self.pkContains(pk)) return error.DuplicatePrimaryKey;
        }
        try self.checkUnique(values, null);
    }

    /// Validate column count and type tags without primary-key or unique
    /// checks. Used by the commit coordinator when a target row was inserted by
    /// the same write set and is not yet visible to the live table.
    pub fn validateTypes(self: *const Table, values: []const value.Value) Error!void {
        try self.checkTypes(values);
    }

    pub fn validateUpdate(self: *const Table, pk: value.Value, values: []const value.Value) Error!void {
        try self.checkTypes(values);
        const pk_index = self.pk_index orelse return error.MissingPrimaryKey;
        if (!value.Value.eql(values[pk_index], pk)) return error.PrimaryKeyImmutable;
        const idx = self.pkLookup(pk) orelse return error.PrimaryKeyNotFound;
        try self.checkUnique(values, idx);
    }

    /// Preflight for index-addressed replace (including no single-column PK).
    pub fn validateUpdateAt(self: *const Table, idx: usize, values: []const value.Value) Error!void {
        if (idx >= self.rows.items.len) return error.PrimaryKeyNotFound;
        try self.checkTypes(values);
        try self.checkUnique(values, idx);
        if (self.pk_index) |pki| {
            if (!value.Value.eql(self.rows.items[idx].values[pki], values[pki])) {
                return error.PrimaryKeyImmutable;
            }
        }
    }

    pub fn insert(self: *Table, gpa: Allocator, values: []const value.Value, commit_seq: u64) (Error || Allocator.Error)!void {
        try self.validateInsert(values);

        const owned_vals = try gpa.alloc(value.Value, values.len);
        errdefer gpa.free(owned_vals);
        var n: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < n) : (j += 1) owned_vals[j].deinit(gpa);
        }
        while (n < values.len) : (n += 1) {
            owned_vals[n] = try values[n].clone(gpa);
        }

        const idx = self.rows.items.len;
        try self.rows.append(gpa, .{ .values = owned_vals, .version = self.next_version, .created_seq = commit_seq });
        self.next_version += 1;
        errdefer {
            var row = self.rows.pop().?;
            row.deinit(gpa);
        }
        if (self.pk_index) |pki| {
            const stored_pk = self.rows.items[idx].values[pki];
            try self.pkPut(stored_pk, idx);
            if (stored_pk == .int) {
                if (stored_pk.int >= self.next_serial) self.next_serial = stored_pk.int + 1;
            }
        }
        for (self.columns, 0..) |col, ci| {
            if (col.serial and values[ci] == .int) {
                if (values[ci].int >= self.next_serial) self.next_serial = values[ci].int + 1;
            }
        }
    }

    pub fn update(self: *Table, gpa: Allocator, pk: value.Value, values: []const value.Value, commit_seq: u64) (Error || Allocator.Error)!void {
        try self.validateUpdate(pk, values);
        const pki = self.pk_index.?;
        const idx = self.pkLookup(pk).?;

        const owned_vals = try gpa.alloc(value.Value, values.len);
        errdefer gpa.free(owned_vals);
        var n: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < n) : (j += 1) owned_vals[j].deinit(gpa);
        }
        while (n < values.len) : (n += 1) {
            owned_vals[n] = try values[n].clone(gpa);
        }

        // UPDATE creates a new version and ends the old version's visibility
        // interval at `commit_seq`: retain the superseded live row first (it
        // owns independent copies, so freeing the live row cannot affect it).
        const old = self.rows.items[idx];
        try self.retainVersion(gpa, pk, old, commit_seq);

        self.pkRemove(pk);
        self.rows.items[idx].deinit(gpa);
        self.rows.items[idx] = .{ .values = owned_vals, .version = self.next_version, .created_seq = commit_seq };
        self.next_version += 1;
        try self.pkPut(self.rows.items[idx].values[pki], idx);
    }

    /// Replace row at stable index (tables without single-column PK, or
    /// by-index updates). Heap tables cannot address old versions by key, so
    /// the superseded row is NOT retained: its version interval ends at the
    /// replace and it is freed. Tables with a single-column PK route through
    /// `update` and do retain.
    pub fn updateAt(self: *Table, gpa: Allocator, idx: usize, values: []const value.Value, commit_seq: u64) (Error || Allocator.Error)!void {
        if (idx >= self.rows.items.len) return error.PrimaryKeyNotFound;
        try self.checkTypes(values);
        try self.checkUnique(values, idx);

        if (self.pk_index) |pki| {
            const old_pk = self.rows.items[idx].values[pki];
            const new_pk = values[pki];
            if (!value.Value.eql(old_pk, new_pk)) return error.PrimaryKeyImmutable;
            self.pkRemove(old_pk);
        }

        const owned_vals = try gpa.alloc(value.Value, values.len);
        errdefer gpa.free(owned_vals);
        var n: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < n) : (j += 1) owned_vals[j].deinit(gpa);
        }
        while (n < values.len) : (n += 1) {
            owned_vals[n] = try values[n].clone(gpa);
        }

        self.rows.items[idx].deinit(gpa);
        self.rows.items[idx] = .{ .values = owned_vals, .version = self.next_version, .created_seq = commit_seq };
        self.next_version += 1;
        if (self.pk_index) |pki| {
            try self.pkPut(self.rows.items[idx].values[pki], idx);
        }
    }

    pub fn delete(self: *Table, gpa: Allocator, pk: value.Value, commit_seq: u64) (Error || Allocator.Error)!void {
        const idx = self.pkLookup(pk) orelse return error.PrimaryKeyNotFound;
        try self.deleteAt(gpa, idx, commit_seq);
    }

    pub fn deleteAt(self: *Table, gpa: Allocator, idx: usize, commit_seq: u64) (Error || Allocator.Error)!void {
        if (idx >= self.rows.items.len) return error.PrimaryKeyNotFound;

        // DELETE only ends the old version's visibility interval at
        // `commit_seq`. Single-column-PK tables retain the superseded version
        // so snapshots older than the delete still see it; heap tables cannot
        // address versions by key and free the row.
        if (self.pk_index) |pki| {
            const old = self.rows.items[idx];
            try self.retainVersion(gpa, old.values[pki], old, commit_seq);
            self.pkRemove(old.values[pki]);
        }

        const last = self.rows.items.len - 1;
        var removed = self.rows.items[idx];
        if (idx != last) {
            const moved = self.rows.items[last];
            self.rows.items[idx] = moved;
            if (self.pk_index) |pki| {
                try self.pkPut(moved.values[pki], idx);
            }
        }
        _ = self.rows.pop();
        removed.deinit(gpa);
    }

    pub fn allocSerial(self: *Table) i64 {
        const id = self.next_serial;
        self.next_serial += 1;
        return id;
    }

    pub fn columnIndex(self: *const Table, name: []const u8) ?usize {
        for (self.columns, 0..) |col, i| {
            if (std.ascii.eqlIgnoreCase(col.name, name)) return i;
        }
        return null;
    }

    /// Applies a precomputed value to every existing row, then publishes the
    /// column definition. Engine owns evaluation of dynamic defaults and WAL.
    pub fn addColumn(self: *Table, gpa: Allocator, column: value.Column, existing_value: value.Value) (Error || Allocator.Error)!void {
        if (self.columnIndex(column.name) != null) return error.ColumnExists;
        if (column.primary_key) return error.MissingPrimaryKey;
        if (column.not_null and existing_value == .null and self.rows.items.len != 0) return error.NotNullViolation;

        const new_columns = try gpa.realloc(self.columns, self.columns.len + 1);
        self.columns = new_columns;
        errdefer self.columns = gpa.realloc(self.columns, self.columns.len - 1) catch self.columns;
        self.columns[self.columns.len - 1] = try column.clone(gpa);

        for (self.rows.items) |*row| {
            const values = try gpa.realloc(row.values, row.values.len + 1);
            row.values = values;
            row.values[row.values.len - 1] = try existing_value.clone(gpa);
        }
    }

    pub fn dropColumn(self: *Table, gpa: Allocator, name: []const u8) (Error || Allocator.Error)!void {
        const idx = self.columnIndex(name) orelse return error.ColumnNotFound;
        if (self.pk_index != null and self.pk_index.? == idx) return error.CannotDropPrimaryKey;

        var removed = self.columns[idx];
        var i = idx;
        while (i + 1 < self.columns.len) : (i += 1) self.columns[i] = self.columns[i + 1];
        self.columns = try gpa.realloc(self.columns, self.columns.len - 1);
        removed.deinit(gpa);

        for (self.rows.items) |*row| {
            var removed_value = row.values[idx];
            i = idx;
            while (i + 1 < row.values.len) : (i += 1) row.values[i] = row.values[i + 1];
            row.values = try gpa.realloc(row.values, row.values.len - 1);
            removed_value.deinit(gpa);
        }
        if (self.pk_index) |pki| {
            if (pki > idx) self.pk_index = pki - 1;
        }
    }

    pub fn setDefault(self: *Table, gpa: Allocator, name: []const u8, default_expr: value.DefaultExpr) (Error || Allocator.Error)!void {
        const idx = self.columnIndex(name) orelse return error.ColumnNotFound;
        self.columns[idx].default_expr.deinit(gpa);
        self.columns[idx].default_expr = try default_expr.clone(gpa);
    }

    pub fn setNotNull(self: *Table, name: []const u8, enabled: bool) Error!void {
        const idx = self.columnIndex(name) orelse return error.ColumnNotFound;
        if (enabled) {
            for (self.rows.items) |row| if (row.values[idx] == .null) return error.NotNullViolation;
        }
        self.columns[idx].not_null = enabled;
    }

    /// Collect row indices matching all predicates (AND). Caller owns the slice.
    pub fn matchIndices(self: *const Table, gpa: Allocator, preds: []const Pred) Allocator.Error![]usize {
        var out: std.ArrayList(usize) = .empty;
        errdefer out.deinit(gpa);

        // Fast path: single PK equality
        if (preds.len == 1 and preds[0] == .eq) {
            if (self.pk_index) |pki| {
                const p = preds[0].eq;
                if (p.col_index == pki and p.value == .int and !self.pkIsText()) {
                    if (self.by_pk_int.get(p.value.int)) |idx| {
                        try out.append(gpa, idx);
                    }
                    return try out.toOwnedSlice(gpa);
                }
                if (p.col_index == pki and p.value == .text and self.pkIsText()) {
                    if (self.by_pk_text.get(p.value.text)) |idx| {
                        try out.append(gpa, idx);
                    }
                    return try out.toOwnedSlice(gpa);
                }
            }
        }

        for (self.rows.items, 0..) |row, idx| {
            if (valuesMatch(row.values, preds)) {
                try out.append(gpa, idx);
            }
        }
        return try out.toOwnedSlice(gpa);
    }

    /// Clone the superseded live row `old` into the retention store, ending its
    /// visibility interval at `deleted_seq`. The retained version owns copies,
    /// so freeing the live row afterwards cannot affect it.
    fn retainVersion(self: *Table, gpa: Allocator, pk: value.Value, old: Row, deleted_seq: u64) Allocator.Error!void {
        var retained_pk = try pk.clone(gpa);
        errdefer retained_pk.deinit(gpa);
        const vals = try gpa.alloc(value.Value, old.values.len);
        errdefer gpa.free(vals);
        var cloned: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < cloned) : (i += 1) vals[i].deinit(gpa);
        }
        while (cloned < old.values.len) : (cloned += 1) {
            vals[cloned] = try old.values[cloned].clone(gpa);
        }
        try self.retained.append(gpa, .{
            .pk = retained_pk,
            .values = vals,
            .created_seq = old.created_seq,
            .deleted_seq = deleted_seq,
            .version = old.version,
        });
    }

    /// The newest retained version of `pk` visible at snapshot `s`, or null.
    /// Borrowed; a live row supersedes retained versions in the scan helpers,
    /// so this is the fallback when no live row is visible at `s`.
    pub fn retainedVersionAt(self: *const Table, pk: value.Value, s: u64) ?*const RetainedVersion {
        var best: ?*const RetainedVersion = null;
        for (self.retained.items) |*rv| {
            if (!value.Value.eql(rv.pk, pk)) continue;
            if (!mvcc.visible(rv.created_seq, rv.deleted_seq, s)) continue;
            if (best) |b| {
                if (rv.created_seq > b.created_seq) best = rv;
            } else best = rv;
        }
        return best;
    }

    /// Whether `pk` has any committed version visible at snapshot `s` (a live
    /// row created at or before `s`, or a retained version whose interval
    /// contains `s`).
    pub fn pkVisibleAt(self: *const Table, pk: value.Value, s: u64) bool {
        if (self.pkLookup(pk)) |idx| {
            if (self.rows.items[idx].created_seq <= s) return true;
        }
        return self.retainedVersionAt(pk, s) != null;
    }

    /// The owned row version of `pk` visible at snapshot `s`, or null when `pk`
    /// has no version visible at `s`. Clones the visible version (a live row
    /// created at or before `s`, else the newest retained version whose interval
    /// contains `s`).
    pub fn rowVisibleAt(self: *const Table, gpa: Allocator, pk: value.Value, s: u64) Allocator.Error!?Row {
        if (self.pkLookup(pk)) |idx| {
            const row = self.rows.items[idx];
            if (row.created_seq <= s) return try row.clone(gpa);
        }
        if (self.retainedVersionAt(pk, s)) |rv| {
            return try rowFromRetained(gpa, rv);
        }
        return null;
    }

    /// Collect owned clones of every version visible at snapshot `s`: live rows
    /// created at or before `s`, plus retained versions visible at `s` not
    /// superseded by a live row visible at `s`. One version per primary key, in
    /// live-row order followed by retained order. The caller owns the result.
    pub fn rowsVisibleAt(self: *const Table, gpa: Allocator, s: u64) Allocator.Error![]Row {
        var out: std.ArrayList(Row) = .empty;
        errdefer {
            for (out.items) |*r| r.deinit(gpa);
            out.deinit(gpa);
        }
        // Reserve capacity before cloning so a failed clone cannot leak the
        // already-cloned row (appendAssumeCapacity is infallible).
        for (self.rows.items) |row| {
            if (row.created_seq > s) continue;
            try out.ensureUnusedCapacity(gpa, 1);
            out.appendAssumeCapacity(try row.clone(gpa));
        }
        for (self.retained.items) |*rv| {
            if (!mvcc.visible(rv.created_seq, rv.deleted_seq, s)) continue;
            if (self.pkLookup(rv.pk)) |idx| {
                if (self.rows.items[idx].created_seq <= s) continue; // live row supersedes
            }
            try out.ensureUnusedCapacity(gpa, 1);
            out.appendAssumeCapacity(try rowFromRetained(gpa, rv));
        }
        return try out.toOwnedSlice(gpa);
    }

    /// Number of retained versions currently held (MVCC retention
    /// observability; roadmap Phase 5 required metric "unreclaimable version
    /// count" derives from this and `unreclaimableRetainedCount`).
    pub fn retainedVersionCount(self: *const Table) usize {
        return self.retained.items.len;
    }

    /// Number of retained versions some active snapshot can still see, i.e.
    /// versions NOT reclaimable at `oldest_active_snapshot_seq`: those with
    /// `deleted_seq >= oldest_active_snapshot_seq`. A version with
    /// `deleted_seq < oldest` is invisible to every active snapshot (every
    /// registered watermark is `>= oldest`, and visibility requires
    /// `s < deleted_seq`), so reclamation may free it.
    pub fn unreclaimableRetainedCount(self: *const Table, oldest_active_snapshot_seq: u64) usize {
        var n: usize = 0;
        for (self.retained.items) |rv| {
            if (rv.deleted_seq >= oldest_active_snapshot_seq) n += 1;
        }
        return n;
    }

    /// Free and remove every retained version invisible to every active
    /// snapshot: versions with `deleted_seq < oldest_active_snapshot_seq`.
    /// Never touches live rows. Returns the number of versions reclaimed.
    pub fn reclaimRetained(self: *Table, gpa: Allocator, oldest_active_snapshot_seq: u64) usize {
        var i: usize = 0;
        var reclaimed: usize = 0;
        while (i < self.retained.items.len) {
            const v = self.retained.items[i];
            if (v.deleted_seq < oldest_active_snapshot_seq) {
                const last = self.retained.items.len - 1;
                if (i != last) self.retained.items[i] = self.retained.items[last];
                _ = self.retained.pop();
                var removed = v;
                removed.deinit(gpa);
                reclaimed += 1;
                // Don't advance `i`: the swapped-in element must be examined.
            } else {
                i += 1;
            }
        }
        return reclaimed;
    }
};

fn rowFromRetained(gpa: Allocator, rv: *const RetainedVersion) Allocator.Error!Row {
    const vals = try gpa.alloc(value.Value, rv.values.len);
    errdefer gpa.free(vals);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) vals[j].deinit(gpa);
    }
    while (i < rv.values.len) : (i += 1) vals[i] = try rv.values[i].clone(gpa);
    return .{ .values = vals, .version = rv.version, .created_seq = rv.created_seq };
}

/// Execution-layer predicate bound to column indices.
pub const Pred = union(enum) {
    eq: struct {
        col_index: usize,
        value: value.Value, // borrowed during match
    },
    is_null: struct {
        col_index: usize,
        negated: bool,
    },
    cmp: struct {
        col_index: usize,
        op: CmpOp,
        value: value.Value, // borrowed during match
    },
    in_list: struct {
        col_index: usize,
        values: []const value.Value, // borrowed during match
        negated: bool,
    },
    like: struct {
        col_index: usize,
        pattern: value.Value, // borrowed during match
        negated: bool,
    },
    /// OR of AND-groups: true if any group fully matches
    or_group: struct {
        groups: [][]Pred, // owned; each inner slice AND-combined
    },

    pub const CmpOp = enum(u8) {
        neq,
        lt,
        gt,
        lte,
        gte,
    };
};

/// Match a borrowed value slice against AND-combined predicates. Shared by row
/// and view matching so evidence filtering uses the same semantics.
pub fn valuesMatch(values: []const value.Value, preds: []const Pred) bool {
    for (preds) |p| {
        switch (p) {
            .eq => |e| {
                if (!value.Value.eql(values[e.col_index], e.value)) return false;
            },
            .is_null => |n| {
                const is_null = values[n.col_index] == .null;
                if (n.negated) {
                    if (is_null) return false;
                } else {
                    if (!is_null) return false;
                }
            },
            .cmp => |c| {
                const ord = value.Value.order(values[c.col_index], c.value) orelse return false;
                const pass = switch (c.op) {
                    .neq => ord != .eq,
                    .lt => ord == .lt,
                    .gt => ord == .gt,
                    .lte => ord != .gt,
                    .gte => ord != .lt,
                };
                if (!pass) return false;
            },
            .in_list => |list| {
                if (!value.matchesIn(values[list.col_index], list.values, list.negated)) return false;
            },
            .like => |like| {
                if (!value.matchesLike(values[like.col_index], like.pattern, like.negated)) return false;
            },
            .or_group => |o| {
                var any_match = false;
                for (o.groups) |group| {
                    if (valuesMatch(values, group)) {
                        any_match = true;
                        break;
                    }
                }
                if (!any_match) return false;
            },
        }
    }
    return true;
}

test "table insert rejects duplicate primary key" {
    const gpa = std.testing.allocator;
    var table = try Table.create(gpa, "users", &.{
        .{ .name = "id", .type_tag = .int, .primary_key = true },
        .{ .name = "email", .type_tag = .text, .unique = true },
    });
    defer table.deinit(gpa);

    var alice: value.Value = .{ .text = try gpa.dupe(u8, "alice@example.com") };
    defer alice.deinit(gpa);
    var bob: value.Value = .{ .text = try gpa.dupe(u8, "bob@example.com") };
    defer bob.deinit(gpa);

    try table.insert(gpa, &.{ .{ .int = 1 }, alice }, 1);
    try std.testing.expectError(error.DuplicatePrimaryKey, table.insert(gpa, &.{ .{ .int = 1 }, bob }, 2));
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
}

test "table insert and update enforce unique" {
    const gpa = std.testing.allocator;
    var table = try Table.create(gpa, "users", &.{
        .{ .name = "id", .type_tag = .int, .primary_key = true },
        .{ .name = "email", .type_tag = .text, .unique = true },
    });
    defer table.deinit(gpa);

    var alice: value.Value = .{ .text = try gpa.dupe(u8, "alice@example.com") };
    defer alice.deinit(gpa);
    var bob: value.Value = .{ .text = try gpa.dupe(u8, "bob@example.com") };
    defer bob.deinit(gpa);

    try table.insert(gpa, &.{ .{ .int = 1 }, alice }, 1);
    try table.insert(gpa, &.{ .{ .int = 2 }, bob }, 2);
    try std.testing.expectError(
        error.UniqueViolation,
        table.update(gpa, .{ .int = 2 }, &.{ .{ .int = 2 }, alice }, 3),
    );
}

test "table primary key is immutable on update" {
    const gpa = std.testing.allocator;
    var table = try Table.create(gpa, "users", &.{
        .{ .name = "id", .type_tag = .int, .primary_key = true },
        .{ .name = "name", .type_tag = .text },
    });
    defer table.deinit(gpa);

    var name: value.Value = .{ .text = try gpa.dupe(u8, "alice") };
    defer name.deinit(gpa);
    try table.insert(gpa, &.{ .{ .int = 1 }, name }, 1);

    var name2: value.Value = .{ .text = try gpa.dupe(u8, "bob") };
    defer name2.deinit(gpa);
    try std.testing.expectError(
        error.PrimaryKeyImmutable,
        table.update(gpa, .{ .int = 1 }, &.{ .{ .int = 99 }, name2 }, 2),
    );
}

test "table matchIndices eq on pk and scan" {
    const gpa = std.testing.allocator;
    var table = try Table.create(gpa, "users", &.{
        .{ .name = "id", .type_tag = .int, .primary_key = true },
        .{ .name = "name", .type_tag = .text },
    });
    defer table.deinit(gpa);

    var a: value.Value = .{ .text = try gpa.dupe(u8, "alice") };
    defer a.deinit(gpa);
    var b: value.Value = .{ .text = try gpa.dupe(u8, "bob") };
    defer b.deinit(gpa);
    try table.insert(gpa, &.{ .{ .int = 1 }, a }, 1);
    try table.insert(gpa, &.{ .{ .int = 2 }, b }, 2);

    const pk_preds = [_]Pred{.{ .eq = .{ .col_index = 0, .value = .{ .int = 2 } } }};
    const by_pk = try table.matchIndices(gpa, &pk_preds);
    defer gpa.free(by_pk);
    try std.testing.expectEqual(@as(usize, 1), by_pk.len);
    try std.testing.expectEqual(@as(usize, 1), by_pk[0]);

    const name_preds = [_]Pred{.{ .eq = .{ .col_index = 1, .value = a } }};
    const by_name = try table.matchIndices(gpa, &name_preds);
    defer gpa.free(by_name);
    try std.testing.expectEqual(@as(usize, 1), by_name.len);
    try std.testing.expectEqual(@as(usize, 0), by_name[0]);
}

test "table delete swaps last row and fixes pk index" {
    const gpa = std.testing.allocator;
    var table = try Table.create(gpa, "users", &.{
        .{ .name = "id", .type_tag = .int, .primary_key = true },
        .{ .name = "name", .type_tag = .text },
    });
    defer table.deinit(gpa);

    var a: value.Value = .{ .text = try gpa.dupe(u8, "a") };
    defer a.deinit(gpa);
    var b: value.Value = .{ .text = try gpa.dupe(u8, "b") };
    defer b.deinit(gpa);
    var c: value.Value = .{ .text = try gpa.dupe(u8, "c") };
    defer c.deinit(gpa);
    try table.insert(gpa, &.{ .{ .int = 1 }, a }, 1);
    try table.insert(gpa, &.{ .{ .int = 2 }, b }, 2);
    try table.insert(gpa, &.{ .{ .int = 3 }, c }, 3);

    try table.delete(gpa, .{ .int = 1 }, 4);
    try std.testing.expectEqual(@as(usize, 2), table.rows.items.len);
    try std.testing.expect(table.pkLookup(.{ .int = 1 }) == null);
    try std.testing.expect(table.pkLookup(.{ .int = 3 }) != null);
    try std.testing.expect(table.pkLookup(.{ .int = 2 }) != null);
}

test "versioned update retains the superseded version and stamps created_seq" {
    const gpa = std.testing.allocator;
    var table = try Table.create(gpa, "users", &.{
        .{ .name = "id", .type_tag = .int, .primary_key = true },
        .{ .name = "v", .type_tag = .int },
    });
    defer table.deinit(gpa);

    try table.insert(gpa, &.{ .{ .int = 1 }, .{ .int = 10 } }, 1);
    try table.insert(gpa, &.{ .{ .int = 2 }, .{ .int = 20 } }, 2);

    // Live rows carry their creating commit sequence.
    try std.testing.expectEqual(@as(u64, 1), table.rows.items[0].created_seq);
    try std.testing.expectEqual(@as(u64, 2), table.rows.items[1].created_seq);

    try table.update(gpa, .{ .int = 1 }, &.{ .{ .int = 1 }, .{ .int = 11 } }, 3);

    // The old version was retained with the update's commit sequence; the live
    // row now carries the update's created sequence.
    try std.testing.expectEqual(@as(usize, 1), table.retained.items.len);
    try std.testing.expectEqual(@as(u64, 1), table.retained.items[0].created_seq);
    try std.testing.expectEqual(@as(u64, 3), table.retained.items[0].deleted_seq);
    try std.testing.expectEqual(@as(i64, 10), table.retained.items[0].values[1].int);
    try std.testing.expectEqual(@as(u64, 3), table.rows.items[0].created_seq);
    try std.testing.expectEqual(@as(i64, 11), table.rows.items[0].values[1].int);
}

test "versioned delete retains the superseded version and removes the live row" {
    const gpa = std.testing.allocator;
    var table = try Table.create(gpa, "users", &.{
        .{ .name = "id", .type_tag = .int, .primary_key = true },
        .{ .name = "v", .type_tag = .int },
    });
    defer table.deinit(gpa);

    try table.insert(gpa, &.{ .{ .int = 1 }, .{ .int = 10 } }, 1);
    try table.delete(gpa, .{ .int = 1 }, 2);

    // Removed from the live index and row set; retained with the delete's seq.
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expect(table.pkLookup(.{ .int = 1 }) == null);
    try std.testing.expectEqual(@as(usize, 1), table.retained.items.len);
    try std.testing.expectEqual(@as(u64, 2), table.retained.items[0].deleted_seq);
    try std.testing.expectEqual(@as(i64, 10), table.retained.items[0].values[1].int);

    // Reinsert after delete works and creates a fresh live version.
    try table.insert(gpa, &.{ .{ .int = 1 }, .{ .int = 100 } }, 3);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 3), table.rows.items[0].created_seq);
    try std.testing.expect(table.pkLookup(.{ .int = 1 }) != null);
    // The reinsert does not retain; only the delete's retained version remains.
    try std.testing.expectEqual(@as(usize, 1), table.retained.items.len);
}

test "reclaimRetained frees only reclaimable versions and never a live row" {
    const gpa = std.testing.allocator;
    var table = try Table.create(gpa, "users", &.{
        .{ .name = "id", .type_tag = .int, .primary_key = true },
        .{ .name = "v", .type_tag = .int },
    });
    defer table.deinit(gpa);

    // Row 1: insert at 1, update at 2, delete at 3 → retained (1,2) and (2,3).
    try table.insert(gpa, &.{ .{ .int = 1 }, .{ .int = 10 } }, 1);
    try table.update(gpa, .{ .int = 1 }, &.{ .{ .int = 1 }, .{ .int = 11 } }, 2);
    try table.delete(gpa, .{ .int = 1 }, 3);
    // Row 2: insert at 4, update at 5 → retained (4,5).
    try table.insert(gpa, &.{ .{ .int = 2 }, .{ .int = 20 } }, 4);
    try table.update(gpa, .{ .int = 2 }, &.{ .{ .int = 2 }, .{ .int = 21 } }, 5);

    try std.testing.expectEqual(@as(usize, 3), table.retained.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);

    // oldest active snapshot = 3: only deleted_seq < 3 is reclaimable → (1,2).
    try std.testing.expectEqual(@as(usize, 1), table.reclaimRetained(gpa, 3));
    try std.testing.expectEqual(@as(usize, 2), table.retained.items.len);
    // Live rows are never reclaimed.
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);

    // oldest active snapshot = 6: everything retained is reclaimable.
    try std.testing.expectEqual(@as(usize, 2), table.reclaimRetained(gpa, 6));
    try std.testing.expectEqual(@as(usize, 0), table.retained.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
}

test "table snapshot reads expose version history across update, delete, reinsert" {
    const gpa = std.testing.allocator;
    var table = try Table.create(gpa, "users", &.{
        .{ .name = "id", .type_tag = .int, .primary_key = true },
        .{ .name = "v", .type_tag = .int },
    });
    defer table.deinit(gpa);

    try table.insert(gpa, &.{ .{ .int = 1 }, .{ .int = 10 } }, 1);
    try table.update(gpa, .{ .int = 1 }, &.{ .{ .int = 1 }, .{ .int = 11 } }, 2);
    try table.delete(gpa, .{ .int = 1 }, 3);
    try table.insert(gpa, &.{ .{ .int = 1 }, .{ .int = 100 } }, 4);

    // At s=1 the original version (v=10) is visible: the live row was created
    // at 4, after the watermark.
    var v1 = (try table.rowVisibleAt(gpa, .{ .int = 1 }, 1)).?;
    defer v1.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 10), v1.values[1].int);
    try std.testing.expectEqual(@as(u64, 1), v1.created_seq);

    // At s=2 the updated version (v=11) is visible.
    var v2 = (try table.rowVisibleAt(gpa, .{ .int = 1 }, 2)).?;
    defer v2.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 11), v2.values[1].int);

    // At s=3 the row is deleted: absent.
    try std.testing.expect((try table.rowVisibleAt(gpa, .{ .int = 1 }, 3)) == null);

    // At s=4 the reinserted row is visible.
    var v4 = (try table.rowVisibleAt(gpa, .{ .int = 1 }, 4)).?;
    defer v4.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 100), v4.values[1].int);

    // rowsVisibleAt at s=2 yields one version per visible pk: the live row (pk
    // 2 absent here) plus the retained v=11 version of pk 1.
    const visible = try table.rowsVisibleAt(gpa, 2);
    defer {
        for (visible) |*r| r.deinit(gpa);
        gpa.free(visible);
    }
    try std.testing.expectEqual(@as(usize, 1), visible.len);
    try std.testing.expectEqual(@as(i64, 11), visible[0].values[1].int);
}

test "heap table assigns created_seq but does not retain superseded versions" {
    const gpa = std.testing.allocator;
    var table = try Table.create(gpa, "events", &.{
        .{ .name = "payload", .type_tag = .text },
    });
    defer table.deinit(gpa);

    var a: value.Value = .{ .text = try gpa.dupe(u8, "a") };
    defer a.deinit(gpa);
    var b: value.Value = .{ .text = try gpa.dupe(u8, "b") };
    defer b.deinit(gpa);
    try table.insert(gpa, &.{a}, 1);
    try table.updateAt(gpa, 0, &.{b}, 2);
    // Heap tables cannot address versions by key: nothing is retained.
    try std.testing.expectEqual(@as(usize, 0), table.retained.items.len);
    try std.testing.expectEqual(@as(u64, 2), table.rows.items[0].created_seq);
    try table.deleteAt(gpa, 0, 3);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), table.retained.items.len);
}
