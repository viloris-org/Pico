const std = @import("std");
const Allocator = std.mem.Allocator;

/// Column scalar type tags for Phase 0 SQL subset.
pub const TypeTag = enum(u8) {
    int = 1,
    text = 2,
    bool = 3,
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
    primary_key: bool,

    pub fn deinit(self: *Column, gpa: Allocator) void {
        gpa.free(self.name);
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
