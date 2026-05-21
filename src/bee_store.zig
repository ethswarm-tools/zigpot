//! BeeStore — a [`Store`] backed by a Bee node's chunk API over HTTP.
//!
//! - `put`: `POST {base}/chunks` with body `span || payload` and the
//!   `Swarm-Postage-Batch-Id` header (uploads require a postage batch).
//!   The address is computed locally (BMT) and returned.
//! - `get`: `GET {base}/chunks/{hex}`, returning the payload (the 8-byte
//!   span prefix is stripped).
//!
//! Plaintext `http://` (e.g. a local node) needs no TLS setup; `https://`
//! endpoints require configuring the client's CA bundle by the caller.

const std = @import("std");
const chunk = @import("chunk.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;

pub const BeeStore = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    client: std.http.Client,
    base_url: []const u8,
    /// Postage batch id (hex). Required for `put`; `get` ignores it.
    batch_id: ?[]const u8,

    /// `io` comes from the caller's event loop (e.g. one `std.Io.Threaded`
    /// shared across stores); the HTTP client borrows it.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, base_url: []const u8, batch_id: ?[]const u8) BeeStore {
        return .{
            .io = io,
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = io },
            .base_url = std.mem.trim(u8, base_url, "/"),
            .batch_id = batch_id,
        };
    }

    pub fn deinit(self: *BeeStore) void {
        self.client.deinit();
    }

    pub fn store(self: *BeeStore) Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Store.VTable{ .put = putImpl, .get = getImpl };

    fn putImpl(ptr: *anyopaque, payload: []const u8) anyerror!chunk.Address {
        const self: *BeeStore = @ptrCast(@alignCast(ptr));
        const batch = self.batch_id orelse return error.MissingPostageBatch;

        const wire = try chunk.encodeChunk(self.allocator, payload);
        defer self.allocator.free(wire);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/chunks", .{self.base_url});
        defer self.allocator.free(url);

        var body = std.Io.Writer.Allocating.init(self.allocator);
        defer body.deinit();

        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = wire,
            .response_writer = &body.writer,
            .extra_headers = &.{
                .{ .name = "swarm-postage-batch-id", .value = batch },
                .{ .name = "content-type", .value = "application/octet-stream" },
            },
        });
        if (res.status != .created and res.status != .ok) return error.UploadFailed;
        return chunk.chunkAddress(payload);
    }

    fn getImpl(ptr: *anyopaque, addr: chunk.Address, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *BeeStore = @ptrCast(@alignCast(ptr));
        const hex = chunk.toHex(addr);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/chunks/{s}", .{ self.base_url, hex[0..] });
        defer self.allocator.free(url);

        var body = std.Io.Writer.Allocating.init(self.allocator);
        defer body.deinit();

        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &body.writer,
        });
        if (res.status == .not_found) return error.ChunkNotFound;
        if (res.status != .ok) return error.DownloadFailed;

        const wire = body.written();
        if (wire.len < chunk.SPAN_SIZE) return error.MalformedChunk;
        return allocator.dupe(u8, wire[chunk.SPAN_SIZE..]);
    }
};

test "BeeStore.put without a postage batch errors before any network" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var bs = BeeStore.init(threaded.io(), testing.allocator, "http://127.0.0.1:1633/", null);
    defer bs.deinit();
    try testing.expectError(error.MissingPostageBatch, bs.store().put("data"));
}

test "BeeStore trims a trailing slash from the base URL" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var bs = BeeStore.init(threaded.io(), testing.allocator, "http://node:1633/", "abc");
    defer bs.deinit();
    try testing.expectEqualStrings("http://node:1633", bs.base_url);
}
