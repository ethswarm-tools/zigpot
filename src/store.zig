//! Chunk store seam: a content-addressed `put(payload) -> address` /
//! `get(address) -> payload` interface, plus an in-memory implementation
//! for tests. The Bee-node HTTP store lives in `bee_store.zig`.
//!
//! Stores work at the *payload* level — the address is derived from the
//! payload via the BMT (`chunk.chunkAddress`), and span framing for the
//! wire is the store's concern, not the caller's.

const std = @import("std");
const chunk = @import("chunk.zig");

/// A pluggable content-addressed chunk store (vtable over `*anyopaque`).
pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (*anyopaque, payload: []const u8) anyerror!chunk.Address,
        get: *const fn (*anyopaque, addr: chunk.Address, allocator: std.mem.Allocator) anyerror![]u8,
    };

    /// Store `payload`, returning its content address.
    pub fn put(self: Store, payload: []const u8) anyerror!chunk.Address {
        return self.vtable.put(self.ptr, payload);
    }

    /// Fetch the payload for `addr`. The returned slice is allocated with
    /// `allocator` and owned by the caller.
    pub fn get(self: Store, addr: chunk.Address, allocator: std.mem.Allocator) anyerror![]u8 {
        return self.vtable.get(self.ptr, addr, allocator);
    }
};

/// In-memory, content-addressed chunk store. Deduplicates by address.
pub const MemStore = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(chunk.Address, []u8),

    pub fn init(allocator: std.mem.Allocator) MemStore {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(chunk.Address, []u8).init(allocator),
        };
    }

    pub fn deinit(self: *MemStore) void {
        var it = self.map.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.map.deinit();
    }

    /// Erased store handle.
    pub fn store(self: *MemStore) Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Number of distinct chunks held.
    pub fn count(self: *const MemStore) usize {
        return self.map.count();
    }

    const vtable = Store.VTable{ .put = putImpl, .get = getImpl };

    fn putImpl(ptr: *anyopaque, payload: []const u8) anyerror!chunk.Address {
        const self: *MemStore = @ptrCast(@alignCast(ptr));
        const addr = chunk.chunkAddress(payload);
        if (!self.map.contains(addr)) {
            const copy = try self.allocator.dupe(u8, payload);
            errdefer self.allocator.free(copy);
            try self.map.put(addr, copy);
        }
        return addr;
    }

    fn getImpl(ptr: *anyopaque, addr: chunk.Address, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *MemStore = @ptrCast(@alignCast(ptr));
        const v = self.map.get(addr) orelse return error.ChunkNotFound;
        return allocator.dupe(u8, v);
    }
};

/// On-disk, content-addressed chunk store: one file per chunk, named by
/// its hex address. Lets zigpot persist locally with no Bee node.
pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,
    owns: bool,

    pub fn init(io: std.Io, path: []const u8) !FileStore {
        const d = if (std.fs.path.isAbsolute(path)) blk: {
            std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch {};
            break :blk try std.Io.Dir.openDirAbsolute(io, path, .{});
        } else try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
        return .{ .io = io, .dir = d, .owns = true };
    }

    /// Wrap an already-open directory (borrowed — not closed on deinit).
    pub fn fromDir(io: std.Io, dir: std.Io.Dir) FileStore {
        return .{ .io = io, .dir = dir, .owns = false };
    }

    pub fn deinit(self: *FileStore) void {
        if (self.owns) self.dir.close(self.io);
    }

    pub fn store(self: *FileStore) Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Store.VTable{ .put = putImpl, .get = getImpl };

    fn putImpl(ptr: *anyopaque, payload: []const u8) anyerror!chunk.Address {
        const self: *FileStore = @ptrCast(@alignCast(ptr));
        const addr = chunk.chunkAddress(payload);
        const hex = chunk.toHex(addr);
        try self.dir.writeFile(self.io, .{ .sub_path = &hex, .data = payload });
        return addr;
    }

    fn getImpl(ptr: *anyopaque, addr: chunk.Address, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *FileStore = @ptrCast(@alignCast(ptr));
        const hex = chunk.toHex(addr);
        const limit = std.Io.Limit.limited(chunk.CHUNK_SIZE + chunk.SPAN_SIZE);
        return self.dir.readFileAlloc(self.io, &hex, allocator, limit) catch |e| switch (e) {
            error.FileNotFound => error.ChunkNotFound,
            else => e,
        };
    }
};

test "FileStore round-trips on disk, content-addressed" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    var fstore = FileStore.fromDir(threaded.io(), tmp.dir);
    defer fstore.deinit();
    const s = fstore.store();

    const addr = try s.put("hello world");
    try testing.expectEqualStrings(
        "92672a471f4419b255d7cb0cf313474a6f5856fb347c5ece85fb706d644b630f",
        &chunk.toHex(addr),
    );
    const got = try s.get(addr, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello world", got);
    try testing.expectError(error.ChunkNotFound, s.get(chunk.chunkAddress("nope"), testing.allocator));
}

test "MemStore put/get round-trips and dedups by address" {
    const testing = std.testing;
    var ms = MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();

    const a1 = try s.put("hello world");
    const a2 = try s.put("hello world"); // same content → same address, deduped
    try testing.expectEqual(a1, a2);
    try testing.expectEqual(@as(usize, 1), ms.count());
    // address matches the canonical BMT vector
    try testing.expectEqualStrings(
        "92672a471f4419b255d7cb0cf313474a6f5856fb347c5ece85fb706d644b630f",
        &chunk.toHex(a1),
    );

    const got = try s.get(a1, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello world", got);

    try testing.expectError(error.ChunkNotFound, s.get(chunk.chunkAddress("absent"), testing.allocator));
}
