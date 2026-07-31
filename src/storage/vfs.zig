//! Storage virtual file system scoped to one instance data directory.
//!
//! Storage code addresses logical file names only.  The VFS owns path
//! resolution and the lifetime of the underlying data-directory handle.
const std = @import("std");
const builtin = @import("builtin");

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
        /// Advisory lock acquired while opening the file.
        lock: Io.File.Lock = .none,
        lock_nonblocking: bool = false,
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
                .lock = options.lock,
                .lock_nonblocking = options.lock_nonblocking,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => if (options.exclusive) return err else try self.dir.openFile(self.io, name, .{
                    .mode = if (options.write) .read_write else .read_only,
                    .lock = options.lock,
                    .lock_nonblocking = options.lock_nonblocking,
                }),
                else => |open_err| return open_err,
            };
            return .{ .io = self.io, .handle = file };
        }

        return .{
            .io = self.io,
            .handle = try self.dir.openFile(self.io, name, .{
                .mode = if (options.write) .read_write else .read_only,
                .lock = options.lock,
                .lock_nonblocking = options.lock_nonblocking,
            }),
        };
    }

    /// Check whether a logical storage file exists. This is advisory only;
    /// callers must still handle a concurrent open or delete failure.
    pub fn exists(self: *const Vfs, name: []const u8) !bool {
        try validateName(name);
        self.dir.access(self.io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |access_err| return access_err,
        };
        return true;
    }

    /// Remove a storage file and persist the directory entry removal.
    pub fn deleteFile(self: *Vfs, name: []const u8) !void {
        try validateName(name);
        try self.dir.deleteFile(self.io, name);
        try syncDir(self.dir, self.io);
    }

    /// Create an unnamed temporary file that can atomically replace `name`.
    /// The caller must write and sync the returned file before calling commit.
    pub fn createAtomicFile(self: *Vfs, name: []const u8) !AtomicFile {
        try validateName(name);
        return .{
            .io = self.io,
            .atomic = try self.dir.createFileAtomic(self.io, name, .{ .replace = true }),
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

    /// Persist file contents without forcing unrelated inode metadata. WAL
    /// frames are append-only, and fdatasync also persists the size change
    /// needed to recover a newly appended frame on Linux.
    pub fn syncData(self: *File) !void {
        if (comptime builtin.os.tag == .linux) {
            try std.posix.fdatasync(self.handle.handle);
        } else {
            try self.handle.sync(self.io);
        }
    }

    pub fn size(self: *File) !u64 {
        return self.handle.length(self.io);
    }

    pub fn truncate(self: *File, new_size: u64) !void {
        try self.handle.setLength(self.io, new_size);
    }
};

/// A file staged off-name and atomically published with a directory sync.
/// This is the publication primitive for manifests and immutable SSTables.
pub const AtomicFile = struct {
    io: Io,
    atomic: Io.File.Atomic,

    pub fn deinit(self: *AtomicFile) void {
        self.atomic.deinit(self.io);
        self.* = undefined;
    }

    pub fn writeAtAll(self: *AtomicFile, data: []const u8, offset: u64) !void {
        try self.atomic.file.writePositionalAll(self.io, data, offset);
    }

    pub fn sync(self: *AtomicFile) !void {
        try self.atomic.file.sync(self.io);
    }

    /// Atomically replace the destination and persist the new directory entry.
    pub fn commit(self: *AtomicFile) !void {
        try self.atomic.replace(self.io);
        try syncDir(self.atomic.dir, self.io);
    }
};

fn syncDir(dir: Io.Dir, io: Io) !void {
    var handle = try dir.openFile(io, ".", .{ .mode = .read_only });
    defer handle.close(io);
    try handle.sync(io);
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or std.fs.path.isAbsolute(name)) return error.InvalidStoragePath;
    if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, '\\') != null) {
        return error.InvalidStoragePath;
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidStoragePath;
}

test "vfs confines storage files to its data directory" {
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-vfs";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var vfs = try Vfs.open(io, dir_name);
    defer vfs.close();

    try std.testing.expectError(error.InvalidStoragePath, vfs.openFile("../outside", .{}));
    try std.testing.expectError(error.InvalidStoragePath, vfs.openFile("nested/file", .{}));

    var file = try vfs.openFile("wal", .{ .create = true });
    defer file.close();
    try file.writeAtAll("runa", 0);
    try std.testing.expectEqual(@as(u64, 4), try file.size());
    try file.truncate(2);
    try std.testing.expectEqual(@as(u64, 2), try file.size());
}

test "vfs atomically publishes and durably removes storage files" {
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-vfs-publish";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var vfs = try Vfs.open(io, dir_name);
    defer vfs.close();

    {
        var original = try vfs.openFile("manifest", .{ .create = true });
        defer original.close();
        try original.writeAtAll("old", 0);
        try original.sync();
    }
    try std.testing.expect(try vfs.exists("manifest"));

    var replacement = try vfs.createAtomicFile("manifest");
    defer replacement.deinit();
    try replacement.writeAtAll("new", 0);
    try replacement.sync();
    try replacement.commit();

    {
        var published = try vfs.openFile("manifest", .{ .write = false });
        defer published.close();
        var content: [3]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 3), try published.readAt(&content, 0));
        try std.testing.expectEqualStrings("new", &content);
    }

    try vfs.deleteFile("manifest");
    try std.testing.expect(!(try vfs.exists("manifest")));
}
