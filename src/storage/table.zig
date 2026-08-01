const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");

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
        return .{ .values = vals };
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

    pub fn insert(self: *Table, gpa: Allocator, values: []const value.Value) (Error || Allocator.Error)!void {
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
        try self.rows.append(gpa, .{ .values = owned_vals, .version = self.next_version });
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

    pub fn update(self: *Table, gpa: Allocator, pk: value.Value, values: []const value.Value) (Error || Allocator.Error)!void {
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

        self.pkRemove(pk);

        var old = self.rows.items[idx];
        old.deinit(gpa);
        self.rows.items[idx] = .{ .values = owned_vals, .version = self.next_version };
        self.next_version += 1;
        try self.pkPut(self.rows.items[idx].values[pki], idx);
    }

    /// Replace row at stable index (tables without single-column PK, or by-index updates).
    pub fn updateAt(self: *Table, gpa: Allocator, idx: usize, values: []const value.Value) (Error || Allocator.Error)!void {
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

        var old = self.rows.items[idx];
        old.deinit(gpa);
        self.rows.items[idx] = .{ .values = owned_vals, .version = self.next_version };
        self.next_version += 1;
        if (self.pk_index) |pki| {
            try self.pkPut(self.rows.items[idx].values[pki], idx);
        }
    }

    pub fn delete(self: *Table, gpa: Allocator, pk: value.Value) (Error || Allocator.Error)!void {
        const idx = self.pkLookup(pk) orelse return error.PrimaryKeyNotFound;
        try self.deleteAt(gpa, idx);
    }

    pub fn deleteAt(self: *Table, gpa: Allocator, idx: usize) (Error || Allocator.Error)!void {
        if (idx >= self.rows.items.len) return error.PrimaryKeyNotFound;

        if (self.pk_index) |pki| {
            self.pkRemove(self.rows.items[idx].values[pki]);
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
};

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

    try table.insert(gpa, &.{ .{ .int = 1 }, alice });
    try std.testing.expectError(error.DuplicatePrimaryKey, table.insert(gpa, &.{ .{ .int = 1 }, bob }));
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

    try table.insert(gpa, &.{ .{ .int = 1 }, alice });
    try table.insert(gpa, &.{ .{ .int = 2 }, bob });
    try std.testing.expectError(
        error.UniqueViolation,
        table.update(gpa, .{ .int = 2 }, &.{ .{ .int = 2 }, alice }),
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
    try table.insert(gpa, &.{ .{ .int = 1 }, name });

    var name2: value.Value = .{ .text = try gpa.dupe(u8, "bob") };
    defer name2.deinit(gpa);
    try std.testing.expectError(
        error.PrimaryKeyImmutable,
        table.update(gpa, .{ .int = 1 }, &.{ .{ .int = 99 }, name2 }),
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
    try table.insert(gpa, &.{ .{ .int = 1 }, a });
    try table.insert(gpa, &.{ .{ .int = 2 }, b });

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
    try table.insert(gpa, &.{ .{ .int = 1 }, a });
    try table.insert(gpa, &.{ .{ .int = 2 }, b });
    try table.insert(gpa, &.{ .{ .int = 3 }, c });

    try table.delete(gpa, .{ .int = 1 });
    try std.testing.expectEqual(@as(usize, 2), table.rows.items.len);
    try std.testing.expect(table.pkLookup(.{ .int = 1 }) == null);
    try std.testing.expect(table.pkLookup(.{ .int = 3 }) != null);
    try std.testing.expect(table.pkLookup(.{ .int = 2 }) != null);
}
