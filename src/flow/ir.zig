//! Canonical Runa Query IR for the initial read-only relation slice.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");

pub const FORMAT_VERSION: u16 = 2;
pub const DEVELOPMENT_MODEL_REVISION: u64 = 0;

pub const IrError = error{
    InvalidFormat,
    UnsupportedVersion,
    StringTooLarge,
    ExpectedField,
    InvalidIdentifier,
    InvalidOperation,
    InvalidModality,
} || Allocator.Error;

pub const Operation = enum(u8) {
    emit = 1,
    observe = 2,
    read_evidence_payload = 3,
};

pub const Observe = struct {
    upload_id: u64,
    object_id: []u8,
    modality: u8,
    media_type: []u8,
    observed_at: []u8,
    origin: []u8,

    fn deinit(self: *Observe, gpa: Allocator) void {
        gpa.free(self.object_id);
        gpa.free(self.media_type);
        gpa.free(self.observed_at);
        gpa.free(self.origin);
    }
};

pub const Request = struct {
    model_revision: u64,
    operation: Operation = .emit,
    relation: []u8,
    fields: [][]u8,
    observe: ?Observe = null,
    evidence_id: u64 = 0,

    pub fn deinit(self: *Request, gpa: Allocator) void {
        gpa.free(self.relation);
        for (self.fields) |field| gpa.free(field);
        gpa.free(self.fields);
        if (self.observe) |*request| request.deinit(gpa);
    }
};

pub fn bind(gpa: Allocator, source: ast.Source) !Request {
    const relation = try gpa.dupe(u8, source.relation);
    errdefer gpa.free(relation);
    const fields = try duplicateFields(gpa, source.fields);
    const request = Request{ .model_revision = DEVELOPMENT_MODEL_REVISION, .relation = relation, .fields = fields };
    try validate(&request);
    return request;
}

/// This encoding is canonical because all strings are bound identifiers and every
/// collection has a fixed order: version, model revision, operation, fields.
pub fn encode(gpa: Allocator, request: *const Request) ![]u8 {
    try validate(request);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try appendInt(&output, gpa, u16, FORMAT_VERSION);
    try appendInt(&output, gpa, u64, request.model_revision);
    try output.append(gpa, @intFromEnum(request.operation));
    switch (request.operation) {
        .emit => {
            try appendString(&output, gpa, request.relation);
            if (request.fields.len > std.math.maxInt(u16)) return error.StringTooLarge;
            try appendInt(&output, gpa, u16, @intCast(request.fields.len));
            for (request.fields) |field| try appendString(&output, gpa, field);
        },
        .observe => {
            const observation = request.observe.?;
            try appendInt(&output, gpa, u64, observation.upload_id);
            try appendString(&output, gpa, observation.object_id);
            try output.append(gpa, observation.modality);
            try appendString(&output, gpa, observation.media_type);
            try appendString(&output, gpa, observation.observed_at);
            try appendString(&output, gpa, observation.origin);
        },
        .read_evidence_payload => try appendInt(&output, gpa, u64, request.evidence_id),
    }
    return output.toOwnedSlice(gpa);
}

pub fn decode(gpa: Allocator, bytes: []const u8) IrError!Request {
    var pos: usize = 0;
    if (try readInt(u16, bytes, &pos) != FORMAT_VERSION) return error.UnsupportedVersion;
    const model_revision = try readInt(u64, bytes, &pos);
    if (pos >= bytes.len) return error.InvalidFormat;
    const operation = std.enums.fromInt(Operation, bytes[pos]) orelse return error.InvalidOperation;
    pos += 1;
    var relation: []u8 = try gpa.alloc(u8, 0);
    var fields: [][]u8 = try gpa.alloc([]u8, 0);
    var observation: ?Observe = null;
    var evidence_id: u64 = 0;
    var transferred = false;
    errdefer {
        if (!transferred) {
            gpa.free(relation);
            for (fields) |field| gpa.free(field);
            gpa.free(fields);
            if (observation) |*item| item.deinit(gpa);
        }
    }
    switch (operation) {
        .emit => {
            const parsed_relation = try readString(gpa, bytes, &pos);
            gpa.free(relation);
            relation = parsed_relation;
            const count = try readInt(u16, bytes, &pos);
            var list: std.ArrayList([]u8) = .empty;
            errdefer {
                for (list.items) |field| gpa.free(field);
                list.deinit(gpa);
            }
            for (0..count) |_| try list.append(gpa, try readString(gpa, bytes, &pos));
            const parsed_fields = try list.toOwnedSlice(gpa);
            gpa.free(fields);
            fields = parsed_fields;
        },
        .observe => observation = try decodeObserve(gpa, bytes, &pos),
        .read_evidence_payload => evidence_id = try readInt(u64, bytes, &pos),
    }
    if (pos != bytes.len) return error.InvalidFormat;
    var request = Request{
        .model_revision = model_revision,
        .operation = operation,
        .relation = relation,
        .fields = fields,
        .observe = observation,
        .evidence_id = evidence_id,
    };
    transferred = true;
    errdefer request.deinit(gpa);
    try validate(&request);
    return request;
}

fn decodeObserve(gpa: Allocator, bytes: []const u8, pos: *usize) IrError!Observe {
    const upload_id = try readInt(u64, bytes, pos);
    const object_id = try readString(gpa, bytes, pos);
    errdefer gpa.free(object_id);
    if (pos.* >= bytes.len) return error.InvalidFormat;
    const modality = bytes[pos.*];
    pos.* += 1;
    const media_type = try readString(gpa, bytes, pos);
    errdefer gpa.free(media_type);
    const observed_at = try readString(gpa, bytes, pos);
    errdefer gpa.free(observed_at);
    const origin = try readString(gpa, bytes, pos);
    return .{ .upload_id = upload_id, .object_id = object_id, .modality = modality, .media_type = media_type, .observed_at = observed_at, .origin = origin };
}

/// Reject structures that cannot be produced by the Runa Flow source grammar.
/// This protects the canonical IR boundary when a client sends IR directly.
pub fn validate(request: *const Request) IrError!void {
    switch (request.operation) {
        .emit => {
            if (request.observe != null or request.evidence_id != 0) return error.InvalidOperation;
            if (!ast.isIdentifier(request.relation)) return error.InvalidIdentifier;
            if (request.fields.len == 0) return error.ExpectedField;
            for (request.fields) |field| if (!ast.isIdentifier(field)) return error.InvalidIdentifier;
        },
        .observe => {
            const observation = request.observe orelse return error.InvalidOperation;
            if (request.relation.len != 0 or request.fields.len != 0 or request.evidence_id != 0) return error.InvalidOperation;
            if (observation.upload_id == 0 or observation.object_id.len == 0 or observation.media_type.len == 0 or observation.observed_at.len == 0 or observation.origin.len == 0) return error.ExpectedField;
            if (observation.modality < 1 or observation.modality > 6) return error.InvalidModality;
        },
        .read_evidence_payload => {
            if (request.relation.len != 0 or request.fields.len != 0 or request.observe != null or request.evidence_id == 0) return error.InvalidOperation;
        },
    }
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

test "IR decode rejects an empty projection" {
    const bytes = [_]u8{
        0, 2, // format version
        0, 0, 0, 0, 0, 0, 0, 0, // model revision
        1, // emit operation
        0, 8, 'c', 'u', 's', 't', 'o', 'm', 'e', 'r', // relation
        0, 0, // field count
    };
    try std.testing.expectError(error.ExpectedField, decode(std.testing.allocator, &bytes));
}

test "IR encode rejects identifiers outside the source grammar" {
    var fields = [_][]u8{@constCast("name")};
    const request = Request{
        .model_revision = DEVELOPMENT_MODEL_REVISION,
        .relation = @constCast("customer-name"),
        .fields = fields[0..],
    };
    try std.testing.expectError(error.InvalidIdentifier, encode(std.testing.allocator, &request));
}

test "IR decodes a canonical observe request" {
    const bytes = [_]u8{
        0, 2, // format version
        0, 0, 0, 0, 0, 0, 0, 0, // model revision
        2, // observe operation
        0, 0, 0,   0,   0,   0, 0, 7, // upload id
        0, 3, 'c', 'a', 'm',
        2, // image modality
        0,
        9,
        'i',
        'm',
        'a',
        'g',
        'e',
        '/',
        'p',
        'n',
        'g',
        0,
        1,
        't',
        0,
        1,
        'o',
    };
    var request = try decode(std.testing.allocator, &bytes);
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(Operation.observe, request.operation);
    try std.testing.expectEqual(@as(u64, 7), request.observe.?.upload_id);
    try std.testing.expectEqualStrings("image/png", request.observe.?.media_type);
}
