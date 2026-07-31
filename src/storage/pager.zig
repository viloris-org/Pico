//! Fixed-size page manager for storage files.
//!
//! The cache owns a compile-time fixed number of page buffers. A caller holds
//! a page by calling `acquire` and must call `release` before it can be
//! evicted. This module deliberately has no transaction, locking, or WAL
//! policy: callers must make dirty-page writeback recoverable before `flush`.
const std = @import("std");
const Io = std.Io;
const vfs_mod = @import("vfs.zig");

pub const default_page_size = 4096;
pub const default_cache_pages = 64;

/// A page manager backed by a static, allocation-free cache.
///
/// `page_size` and `cache_pages` are compile-time constants so cache memory
/// and its upper bound remain explicit in the storage configuration.
pub fn Pager(comptime page_size: usize, comptime cache_pages: usize) type {
    comptime {
        if (page_size == 0) @compileError("page_size must be non-zero");
        if (cache_pages == 0) @compileError("cache_pages must be non-zero");
    }

    return struct {
        const Self = @This();

        pub const Page = struct {
            id: u64 = 0,
            data: [page_size]u8 = [_]u8{0} ** page_size,
            dirty: bool = false,
            pins: usize = 0,
            last_used: u64 = 0,
            resident: bool = false,
        };

        file: vfs_mod.File,
        pages: [cache_pages]Page = [_]Page{.{}} ** cache_pages,
        clock: u64 = 0,

        /// Takes ownership of `file`; `deinit` closes it.
        pub fn init(file: vfs_mod.File) Self {
            return .{ .file = file };
        }

        pub fn deinit(self: *Self) void {
            self.file.close();
            self.* = undefined;
        }

        /// Pins and returns the requested page. Pages past EOF are zero-filled.
        pub fn acquire(self: *Self, page_id: u64) !*Page {
            if (self.find(page_id)) |page| {
                page.pins += 1;
                page.last_used = self.tick();
                return page;
            }

            const page = try self.reservePage();
            if (page.resident and page.dirty) try self.writePage(page);
            try self.readPage(page, page_id);
            page.id = page_id;
            page.resident = true;
            page.dirty = false;
            page.pins = 1;
            page.last_used = self.tick();
            return page;
        }

        /// Releases a page acquired from this pager.
        pub fn release(self: *Self, page: *Page) !void {
            if (!self.owns(page) or !page.resident or page.pins == 0) return error.InvalidPageHandle;
            page.pins -= 1;
            page.last_used = self.tick();
        }

        /// Marks a pinned page for writeback. Data is caller-owned until flush.
        pub fn markDirty(self: *Self, page: *Page) !void {
            if (!self.owns(page) or !page.resident or page.pins == 0) return error.InvalidPageHandle;
            page.dirty = true;
            page.last_used = self.tick();
        }

        /// Writes all dirty pages but leaves them resident.
        pub fn flush(self: *Self) !void {
            for (&self.pages) |*page| {
                if (page.resident and page.dirty) try self.writePage(page);
            }
        }

        /// Makes all completed dirty-page writes durable in the backing file.
        pub fn sync(self: *Self) !void {
            try self.flush();
            try self.file.sync();
        }

        /// Returns the file's logical page count. Partial trailing pages are invalid.
        pub fn pageCount(self: *Self) !u64 {
            const size = try self.file.size();
            const page_bytes: u64 = @intCast(page_size);
            if (size % page_bytes != 0) return error.CorruptPageFile;
            return size / page_bytes;
        }

        /// Discards pages past `page_count` and truncates the backing file.
        pub fn truncate(self: *Self, page_count: u64) !void {
            const new_size = try pageOffset(page_count);
            for (&self.pages) |*page| {
                if (page.resident and page.id >= page_count) {
                    if (page.pins != 0) return error.PagePinned;
                    page.* = .{};
                }
            }
            try self.file.truncate(new_size);
        }

        fn find(self: *Self, page_id: u64) ?*Page {
            for (&self.pages) |*page| {
                if (page.resident and page.id == page_id) return page;
            }
            return null;
        }

        fn reservePage(self: *Self) !*Page {
            for (&self.pages) |*page| {
                if (!page.resident) return page;
            }

            var candidate: ?*Page = null;
            for (&self.pages) |*page| {
                if (page.pins != 0) continue;
                if (candidate == null or page.last_used < candidate.?.last_used) candidate = page;
            }
            return candidate orelse error.CacheFull;
        }

        fn readPage(self: *Self, page: *Page, page_id: u64) !void {
            const offset = try pageOffset(page_id);
            const size = try self.file.size();
            if (offset >= size) {
                @memset(&page.data, 0);
                return;
            }
            if (size - offset < page_size) return error.CorruptPageFile;
            const read_len = try self.file.readAt(&page.data, offset);
            if (read_len != page_size) return error.CorruptPageFile;
        }

        fn writePage(self: *Self, page: *Page) !void {
            std.debug.assert(page.resident and page.dirty);
            try self.file.writeAtAll(&page.data, try pageOffset(page.id));
            page.dirty = false;
        }

        fn owns(self: *Self, target: *Page) bool {
            for (&self.pages) |*page| if (page == target) return true;
            return false;
        }

        fn tick(self: *Self) u64 {
            self.clock +%= 1;
            return self.clock;
        }

        fn pageOffset(page_id: u64) !u64 {
            return std.math.mul(u64, page_id, @as(u64, @intCast(page_size))) catch error.PageOffsetOverflow;
        }
    };
}

pub const DefaultPager = Pager(default_page_size, default_cache_pages);

test "pager zero-fills new pages and writes page-aligned data" {
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-pager-write";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var vfs = try vfs_mod.Vfs.open(io, dir_name);
    defer vfs.close();
    var pager = Pager(16, 2).init(try vfs.openFile("pages", .{ .create = true }));
    defer pager.deinit();

    const page = try pager.acquire(3);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 16, &page.data);
    @memcpy(page.data[0..4], "runa");
    try pager.markDirty(page);
    try pager.release(page);
    try pager.sync();
    try std.testing.expectEqual(@as(u64, 4), try pager.pageCount());
}

test "pager evicts least recently used unpinned page after writeback" {
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-pager-evict";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var vfs = try vfs_mod.Vfs.open(io, dir_name);
    defer vfs.close();
    var pager = Pager(8, 2).init(try vfs.openFile("pages", .{ .create = true }));
    defer pager.deinit();

    const first = try pager.acquire(0);
    @memcpy(first.data[0..3], "one");
    try pager.markDirty(first);
    try pager.release(first);
    const second = try pager.acquire(1);
    try pager.release(second);
    const third = try pager.acquire(2);
    try pager.release(third);

    const reread = try pager.acquire(0);
    defer pager.release(reread) catch unreachable;
    try std.testing.expectEqualSlices(u8, "one", reread.data[0..3]);
}

test "pager does not evict pinned pages or truncate through them" {
    const io = std.testing.io;
    const dir_name = "zig-cache/runadb-test-pager-pins";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var vfs = try vfs_mod.Vfs.open(io, dir_name);
    defer vfs.close();
    var pager = Pager(8, 1).init(try vfs.openFile("pages", .{ .create = true }));
    defer pager.deinit();

    const page = try pager.acquire(1);
    try std.testing.expectError(error.CacheFull, pager.acquire(2));
    try std.testing.expectError(error.PagePinned, pager.truncate(1));
    try pager.release(page);
    try pager.truncate(1);
}
