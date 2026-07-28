const std = @import("std");
const Allocator = std.mem.Allocator;

/// Column scalar type tags for the SQL subset.
/// PG aliases (BIGINT, VARCHAR, TIMESTAMPTZ, JSONB, DECIMAL, …) map into these.
pub const TypeTag = enum(u8) {
    int = 1,
    text = 2,
    bool = 3,
};

/// DEFAULT expression stored on a column definition.
pub const DefaultExpr = union(enum) {
    none,
    /// Evaluate to current UTC timestamp text at INSERT time.
    now,
    /// Owned literal applied when the column is omitted or NULL-defaulted.
    literal: Value,

    pub fn deinit(self: *DefaultExpr, gpa: Allocator) void {
        switch (self.*) {
            .literal => |*v| v.deinit(gpa),
            else => {},
        }
        self.* = .none;
    }

    pub fn clone(self: DefaultExpr, gpa: Allocator) Allocator.Error!DefaultExpr {
        return switch (self) {
            .none => .none,
            .now => .now,
            .literal => |v| .{ .literal = try v.clone(gpa) },
        };
    }
};

/// Runtime value. Text owns its bytes when non-null.
pub const Value = union(enum) {
    null,
    int: i64,
    text: []u8,
    bool: bool,

    pub fn deinit(self: *Value, gpa: Allocator) void {
        switch (self.*) {
            .text => |t| gpa.free(t),
            else => {},
        }
        self.* = .null;
    }

    pub fn clone(self: Value, gpa: Allocator) Allocator.Error!Value {
        return switch (self) {
            .null => .null,
            .int => |i| .{ .int = i },
            .bool => |b| .{ .bool = b },
            .text => |t| .{ .text = try gpa.dupe(u8, t) },
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .null => b == .null,
            .int => |ai| switch (b) {
                .int => |bi| ai == bi,
                else => false,
            },
            .bool => |ab| switch (b) {
                .bool => |bb| ab == bb,
                else => false,
            },
            .text => |at| switch (b) {
                .text => |bt| std.mem.eql(u8, at, bt),
                else => false,
            },
        };
    }

    /// Compare two non-null values of the same type tag.
    /// Returns null if types differ or either value is null.
    pub fn order(a: Value, b: Value) ?std.math.Order {
        return switch (a) {
            .null => null,
            .int => |ai| switch (b) {
                .int => |bi| std.math.order(ai, bi),
                else => null,
            },
            .bool => |ab| switch (b) {
                .bool => |bb| std.math.order(@intFromBool(ab), @intFromBool(bb)),
                else => null,
            },
            .text => |at| switch (b) {
                .text => |bt| std.mem.order(u8, at, bt),
                else => null,
            },
        };
    }

    /// Format for DataRow text protocol.
    pub fn formatText(self: Value, buf: []u8) error{NoSpaceLeft}![]const u8 {
        return switch (self) {
            .null => error.NoSpaceLeft, // caller should send NULL (-1)
            .int => |i| try std.fmt.bufPrint(buf, "{d}", .{i}),
            .bool => |b| if (b) "t" else "f",
            .text => |t| blk: {
                if (t.len > buf.len) return error.NoSpaceLeft;
                @memcpy(buf[0..t.len], t);
                break :blk buf[0..t.len];
            },
        };
    }
};

pub const Column = struct {
    name: []u8,
    type_tag: TypeTag,
    primary_key: bool = false,
    not_null: bool = false,
    unique: bool = false,
    serial: bool = false,
    default_expr: DefaultExpr = .none,

    pub fn deinit(self: *Column, gpa: Allocator) void {
        gpa.free(self.name);
        self.default_expr.deinit(gpa);
    }

    pub fn clone(self: Column, gpa: Allocator) Allocator.Error!Column {
        return .{
            .name = try gpa.dupe(u8, self.name),
            .type_tag = self.type_tag,
            .primary_key = self.primary_key,
            .not_null = self.not_null,
            .unique = self.unique,
            .serial = self.serial,
            .default_expr = try self.default_expr.clone(gpa),
        };
    }
};

test "value clone eql" {
    const gpa = std.testing.allocator;
    var v: Value = .{ .text = try gpa.dupe(u8, "hi") };
    defer v.deinit(gpa);
    var c = try v.clone(gpa);
    defer c.deinit(gpa);
    try std.testing.expect(v.eql(c));
}
