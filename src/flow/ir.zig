//! Canonical Runa Query IR for the initial read-only relation slice.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");

pub const FORMAT_VERSION: u16 = 1;
pub const DEVELOPMENT_MODEL_REVISION: u64 = 0;

pub const IrError = error{ InvalidFormat, UnsupportedVersion, StringTooLarge } || Allocator.Error;

pub const Request = struct {
    model_revision: u64,
    relation: []u8,
    fields: [][]u8,

    pub fn deinit(self: *Request, gpa: Allocator) void {
        gpa.free(self.relation);
        for (self.fields) |field| gpa.free(field);
        gpa.free(self.fields);
    }
};

pub fn bind(gpa: Allocator, source: ast.Source) !Request {
    const relation = try gpa.dupe(u8, source.relation);
    errdefer gpa.free(relation);
    const fields = try duplicateFields(gpa, source.fields);
    return .{ .model_revision = DEVELOPMENT_MODEL_REVISION, .relation = relation, .fields = fields };
}

/// This encoding is canonical because all strings are bound identifiers and every
/// collection has a fixed order: version, model revision, relation, fields.
pub fn encode(gpa: Allocator, request: *const Request) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try appendInt(&output, gpa, u16, FORMAT_VERSION);
    try appendInt(&output, gpa, u64, request.model_revision);
    try appendString(&output, gpa, request.relation);
    if (request.fields.len > std.math.maxInt(u16)) return error.StringTooLarge;
    try appendInt(&output, gpa, u16, @intCast(request.fields.len));
    for (request.fields) |field| try appendString(&output, gpa, field);
    return output.toOwnedSlice(gpa);
}

pub fn decode(gpa: Allocator, bytes: []const u8) IrError!Request {
    var pos: usize = 0;
    if (try readInt(u16, bytes, &pos) != FORMAT_VERSION) return error.UnsupportedVersion;
    const model_revision = try readInt(u64, bytes, &pos);
    const relation = try readString(gpa, bytes, &pos);
    errdefer gpa.free(relation);
    const count = try readInt(u16, bytes, &pos);
    var fields: std.ArrayList([]u8) = .empty;
    errdefer {
        for (fields.items) |field| gpa.free(field);
        fields.deinit(gpa);
    }
    for (0..count) |_| try fields.append(gpa, try readString(gpa, bytes, &pos));
    if (pos != bytes.len) return error.InvalidFormat;
    return .{ .model_revision = model_revision, .relation = relation, .fields = try fields.toOwnedSlice(gpa) };
}

fn duplicateFields(gpa: Allocator, fields: []const []u8) ![][]u8 {
    const result = try gpa.alloc([]u8, fields.len);
    var copied: usize = 0;
    errdefer {
        for (result[0..copied]) |field| gpa.free(field);
        gpa.free(result);
    }
    for (fields, 0..) |field, index| {
        result[index] = try gpa.dupe(u8, field);
        copied += 1;
    }
    return result;
}

fn appendInt(output: *std.ArrayList(u8), gpa: Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .big);
    try output.appendSlice(gpa, &buffer);
}

fn appendString(output: *std.ArrayList(u8), gpa: Allocator, value: []const u8) !void {
    if (value.len > std.math.maxInt(u16)) return error.StringTooLarge;
    try appendInt(output, gpa, u16, @intCast(value.len));
    try output.appendSlice(gpa, value);
}

fn readInt(comptime T: type, bytes: []const u8, pos: *usize) IrError!T {
    if (bytes.len -| pos.* < @sizeOf(T)) return error.InvalidFormat;
    const value = std.mem.readInt(T, bytes[pos.*..][0..@sizeOf(T)], .big);
    pos.* += @sizeOf(T);
    return value;
}

fn readString(gpa: Allocator, bytes: []const u8, pos: *usize) IrError![]u8 {
    const length = try readInt(u16, bytes, pos);
    if (bytes.len -| pos.* < length) return error.InvalidFormat;
    const result = try gpa.dupe(u8, bytes[pos.* .. pos.* + length]);
    pos.* += length;
    return result;
}

test "IR encoding round trips exactly" {
    var source = try ast.parse(std.testing.allocator, "from customer\n| emit { id, name }");
    defer source.deinit(std.testing.allocator);
    var request = try bind(std.testing.allocator, source);
    defer request.deinit(std.testing.allocator);
    const bytes = try encode(std.testing.allocator, &request);
    defer std.testing.allocator.free(bytes);
    var decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("customer", decoded.relation);
    try std.testing.expectEqualStrings("name", decoded.fields[1]);
}
