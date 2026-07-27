//! Storage virtual file system scoped to one instance data directory.
//!
//! Storage code addresses logical file names only.  The VFS owns path
//! resolution and the lifetime of the underlying data-directory handle.
const std = @import("std");

const Io = std.Io;

pub const Vfs = struct {
    io: Io,
    dir: Io.Dir,
    instance_lock: Io.File,

    pub const OpenOptions = struct {
        read: bool = true,
        write: bool = true,
        create: bool = false,
        truncate: bool = false,
        exclusive: bool = false,
    };

    pub fn open(io: Io, data_dir: []const u8) !Vfs {
        const dir = try Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        errdefer dir.close(io);

        const instance_lock = dir.createFile(io, "LOCK", .{ .read = true }) catch |err| switch (err) {
            error.PathAlreadyExists => try dir.openFile(io, "LOCK", .{ .mode = .read_write }),
            else => |open_err| return open_err,
        };
        errdefer instance_lock.close(io);
        if (!(try instance_lock.tryLock(io, .exclusive))) return error.InstanceInUse;

        return .{ .io = io, .dir = dir, .instance_lock = instance_lock };
    }

    pub fn close(self: *Vfs) void {
        self.instance_lock.unlock(self.io);
        self.instance_lock.close(self.io);
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn openFile(self: *Vfs, name: []const u8, options: OpenOptions) !File {
        try validateName(name);

        if (options.create) {
            const file = self.dir.createFile(self.io, name, .{
                .read = options.read,
                .truncate = options.truncate,
                .exclusive = options.exclusive,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => if (options.exclusive) return err else try self.dir.openFile(self.io, name, .{
                    .mode = if (options.write) .read_write else .read_only,
                }),
                else => |open_err| return open_err,
            };
            return .{ .io = self.io, .handle = file };
        }

        return .{
            .io = self.io,
            .handle = try self.dir.openFile(self.io, name, .{
                .mode = if (options.write) .read_write else .read_only,
            }),
        };
    }
};

pub const File = struct {
    io: Io,
    handle: Io.File,

    pub fn close(self: *File) void {
        self.handle.close(self.io);
        self.* = undefined;
    }

    pub fn readAt(self: *File, buffer: []u8, offset: u64) !usize {
        return self.handle.readPositionalAll(self.io, buffer, offset);
    }

    pub fn writeAtAll(self: *File, data: []const u8, offset: u64) !void {
        try self.handle.writePositionalAll(self.io, data, offset);
    }

    pub fn sync(self: *File) !void {
        try self.handle.sync(self.io);
    }

    pub fn size(self: *File) !u64 {
        return self.handle.length(self.io);
    }

    pub fn truncate(self: *File, new_size: u64) !void {
        try self.handle.setLength(self.io, new_size);
    }
};

fn validateName(name: []const u8) !void {
    if (name.len == 0 or std.fs.path.isAbsolute(name)) return error.InvalidStoragePath;
    if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, '\\') != null) {
        return error.InvalidStoragePath;
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidStoragePath;
}

test "vfs confines storage files to its data directory" {
    const io = std.testing.io;
    const dir_name = "zig-cache/pico-test-vfs";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var vfs = try Vfs.open(io, dir_name);
    defer vfs.close();

    try std.testing.expectError(error.InvalidStoragePath, vfs.openFile("../outside", .{}));
    try std.testing.expectError(error.InvalidStoragePath, vfs.openFile("nested/file", .{}));

    var file = try vfs.openFile("wal", .{ .create = true });
    defer file.close();
    try file.writeAtAll("pico", 0);
    try std.testing.expectEqual(@as(u64, 4), try file.size());
    try file.truncate(2);
    try std.testing.expectEqual(@as(u64, 2), try file.size());
}
