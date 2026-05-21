//! zigpot — a Proximity Order Trie (POT) for Swarm, in Zig.
//!
//! Phase 1: the in-memory mutable index. A POT organizes entries by the
//! *proximity order* of their keys — the position of the first bit that
//! differs from a node's pivot key. Lookups branch on PO instead of one
//! bit/byte at a time, so depth is bounded by key-bit length.
//!
//! Phase 2 will add Swarm persistence (BMT/keccak256 chunk addressing +
//! `/chunks` load-save) behind a store seam; the core here is pure and
//! network-free.

const std = @import("std");
const Allocator = std.mem.Allocator;

const chunk = @import("chunk.zig");
const store_mod = @import("store.zig");

/// Re-exports for downstream users.
pub const Store = store_mod.Store;
pub const MemStore = store_mod.MemStore;
pub const FileStore = store_mod.FileStore;
pub const BeeStore = @import("bee_store.zig").BeeStore;
pub const Address = chunk.Address;
pub const chunkAddress = chunk.chunkAddress;
pub const toHex = chunk.toHex;

/// Max forks serialized per node (fork count is a u8 on the wire).
const max_forks = 256;

/// Proximity order of two byte slices: the number of leading bits they
/// share, capped at `max_po`. Higher = more similar. If one slice is a
/// prefix of the other, the shared-bit count is the shorter length × 8.
pub fn proximityOrder(a: []const u8, b: []const u8, max_po: usize) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x: u8 = a[i] ^ b[i];
        if (x != 0) {
            const po = i * 8 + @as(usize, @clz(x));
            return @min(po, max_po);
        }
    }
    return @min(n * 8, max_po);
}

/// A key/value pair owned by the index.
const Entry = struct {
    key: []u8,
    value: []u8,
};

/// One PO-indexed branch from a node to a child sub-trie. Forks are a
/// small singly-linked list per node (a node has at most one fork per
/// distinct PO, and in practice very few), kept allocator-managed to
/// avoid depending on churny container APIs.
const Fork = struct {
    po: usize,
    node: *Node,
    next: ?*Fork,
};

const Node = struct {
    entry: Entry,
    forks: ?*Fork = null,

    fn forkAt(self: *const Node, po: usize) ?*Node {
        var f = self.forks;
        while (f) |fork| : (f = fork.next) {
            if (fork.po == po) return fork.node;
        }
        return null;
    }
};

/// A mutable proximity-order trie keyed by arbitrary byte slices.
///
/// Keys and values are copied in on `put` and freed by `deinit`/`delete`,
/// so callers keep ownership of their buffers. For well-defined proximity
/// order, use fixed-length keys (Swarm uses 32-byte hashed keys).
pub const Index = struct {
    allocator: Allocator,
    root: ?*Node = null,
    max_po: usize,
    len: usize = 0,

    pub fn init(allocator: Allocator, max_po: usize) Index {
        return .{ .allocator = allocator, .max_po = max_po };
    }

    pub fn deinit(self: *Index) void {
        if (self.root) |r| self.freeNode(r);
        self.root = null;
        self.len = 0;
    }

    /// Number of entries currently stored.
    pub fn count(self: *const Index) usize {
        return self.len;
    }

    /// Insert a new entry or update an existing one (by exact key).
    pub fn put(self: *Index, key: []const u8, value: []const u8) Allocator.Error!void {
        if (self.root) |root| {
            try self.insert(root, key, value);
        } else {
            self.root = try self.makeNode(key, value);
            self.len += 1;
        }
    }

    /// Look up a value by exact key, or `null` if absent. The returned
    /// slice is owned by the index and valid until the entry changes.
    pub fn get(self: *const Index, key: []const u8) ?[]const u8 {
        var cur = self.root;
        while (cur) |node| {
            if (std.mem.eql(u8, node.entry.key, key)) return node.entry.value;
            cur = node.forkAt(proximityOrder(node.entry.key, key, self.max_po));
        }
        return null;
    }

    /// True if the key is present.
    pub fn contains(self: *const Index, key: []const u8) bool {
        return self.get(key) != null;
    }

    /// Remove an entry by exact key. Returns true if it existed.
    ///
    /// Phase-1 strategy: detach the node holding the key, then re-insert
    /// its surviving descendants. Simple and correct (not yet the
    /// canonical-form delete needed for stable content-addressed roots —
    /// that lands with Phase 2 persistence).
    pub fn delete(self: *Index, key: []const u8) Allocator.Error!bool {
        const target = self.unlink(key) orelse return false;
        self.len -= subtreeCount(target);
        var f = target.forks;
        while (f) |fork| : (f = fork.next) try self.reinsertSubtree(fork.node);
        self.freeNode(target);
        return true;
    }

    /// Visit every entry (depth-first). `visit` is called once per entry.
    pub fn iterate(
        self: *const Index,
        ctx: anytype,
        comptime visit: fn (@TypeOf(ctx), key: []const u8, value: []const u8) void,
    ) void {
        if (self.root) |r| iterNode(@TypeOf(ctx), r, ctx, visit);
    }

    /// Persist the whole trie to `store` in **canonical** form, returning
    /// the root chunk address — the handle you reload from.
    /// `error.EmptyIndex` if empty.
    ///
    /// Canonical = the on-wire tree depends only on the key/value *set*,
    /// not on insertion order: at each node the pivot is the
    /// lexicographically smallest key and children are bucketed by
    /// proximity order. So identical contents always hash to the same
    /// root (content-addressed dedup across independently built indexes).
    /// Each node becomes one chunk; children are stored first so a parent
    /// can reference them by address.
    pub fn save(self: *Index, store: Store) anyerror!chunk.Address {
        const root = self.root orelse return error.EmptyIndex;
        const entries = try self.allocator.alloc(EntryRef, self.len);
        defer self.allocator.free(entries);
        var idx: usize = 0;
        fillEntries(root, entries, &idx);
        return self.saveCanonical(store, entries);
    }

    /// Recursively serialize a non-empty entry set into canonical chunks.
    /// `entries` is sorted/partitioned in place per level.
    fn saveCanonical(self: *Index, store: Store, entries: []EntryRef) anyerror!chunk.Address {
        // Pivot = lexicographically smallest key (deterministic).
        var pmin: usize = 0;
        for (entries[1..], 1..) |e, i| {
            if (std.mem.order(u8, e.key, entries[pmin].key) == .lt) pmin = i;
        }
        const pivot = entries[pmin];
        std.mem.swap(EntryRef, &entries[0], &entries[pmin]);

        // Group the rest by proximity order to the pivot; one fork per PO.
        const rest = entries[1..];
        std.mem.sort(EntryRef, rest, PoCtx{ .pivot = pivot.key, .max_po = self.max_po }, PoCtx.lessThan);

        var refs: [max_forks]ForkRef = undefined;
        var nrefs: usize = 0;
        var i: usize = 0;
        while (i < rest.len) {
            const po = proximityOrder(pivot.key, rest[i].key, self.max_po);
            var j: usize = i + 1;
            while (j < rest.len and proximityOrder(pivot.key, rest[j].key, self.max_po) == po) : (j += 1) {}
            if (nrefs >= refs.len) return error.NodeTooLarge;
            refs[nrefs] = .{ .po = @intCast(po), .addr = try self.saveCanonical(store, rest[i..j]) };
            nrefs += 1;
            i = j;
        }

        var buf: [chunk.CHUNK_SIZE]u8 = undefined;
        const n = try serializeNode(&buf, pivot.key, pivot.value, refs[0..nrefs]);
        return store.put(buf[0..n]);
    }

    /// Reload a trie saved with [`save`] from its root address.
    pub fn load(allocator: Allocator, store: Store, root_addr: chunk.Address, max_po: usize) anyerror!Index {
        var idx = Index.init(allocator, max_po);
        errdefer idx.deinit();
        idx.root = try idx.loadNode(store, root_addr);
        return idx;
    }

    fn loadNode(self: *Index, store: Store, addr: chunk.Address) anyerror!*Node {
        const payload = try store.get(addr, self.allocator);
        defer self.allocator.free(payload);

        var refs: [max_forks]ForkRef = undefined;
        const parsed = try deserializeNode(payload, &refs);
        const node = try self.makeNode(parsed.key, parsed.value);
        errdefer self.freeNode(node);
        self.len += 1;

        for (parsed.refs) |ref| {
            const child = try self.loadNode(store, ref.addr);
            errdefer self.freeNode(child);
            const fork = try self.allocator.create(Fork);
            fork.* = .{ .po = ref.po, .node = child, .next = node.forks };
            node.forks = fork;
        }
        return node;
    }

    /// Detach (but do not free) the node holding `key`, fixing up the
    /// tree links. Returns the detached node, or null if absent.
    fn unlink(self: *Index, key: []const u8) ?*Node {
        const root = self.root orelse return null;
        if (std.mem.eql(u8, root.entry.key, key)) {
            self.root = null;
            return root;
        }
        var parent = root;
        while (true) {
            const po = proximityOrder(parent.entry.key, key, self.max_po);
            var prev: ?*Fork = null;
            var fk = parent.forks;
            while (fk) |fork| {
                if (fork.po == po) break;
                prev = fork;
                fk = fork.next;
            }
            const fork = fk orelse return null;
            const child = fork.node;
            if (std.mem.eql(u8, child.entry.key, key)) {
                if (prev) |p| p.next = fork.next else parent.forks = fork.next;
                self.allocator.destroy(fork);
                return child;
            }
            parent = child;
        }
    }

    fn insert(self: *Index, node: *Node, key: []const u8, value: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, node.entry.key, key)) {
            const v = try self.allocator.dupe(u8, value);
            self.allocator.free(node.entry.value);
            node.entry.value = v;
            return;
        }
        const po = proximityOrder(node.entry.key, key, self.max_po);
        if (node.forkAt(po)) |child| {
            try self.insert(child, key, value);
            return;
        }
        const child = try self.makeNode(key, value);
        errdefer self.freeNode(child);
        const fork = try self.allocator.create(Fork);
        fork.* = .{ .po = po, .node = child, .next = node.forks };
        node.forks = fork;
        self.len += 1;
    }

    fn makeNode(self: *Index, key: []const u8, value: []const u8) Allocator.Error!*Node {
        const n = try self.allocator.create(Node);
        errdefer self.allocator.destroy(n);
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, value);
        n.* = .{ .entry = .{ .key = k, .value = v }, .forks = null };
        return n;
    }

    fn freeNode(self: *Index, node: *Node) void {
        var f = node.forks;
        while (f) |fork| {
            const next = fork.next;
            self.freeNode(fork.node);
            self.allocator.destroy(fork);
            f = next;
        }
        self.allocator.free(node.entry.key);
        self.allocator.free(node.entry.value);
        self.allocator.destroy(node);
    }

    /// Re-insert an entire subtree's entries into the main tree (used by
    /// delete to reattach survivors). Copies in, so the originals can be
    /// freed afterwards.
    fn reinsertSubtree(self: *Index, node: *Node) Allocator.Error!void {
        try self.put(node.entry.key, node.entry.value);
        var f = node.forks;
        while (f) |fork| : (f = fork.next) try self.reinsertSubtree(fork.node);
    }
};

fn subtreeCount(node: *const Node) usize {
    var c: usize = 1;
    var f = node.forks;
    while (f) |fork| : (f = fork.next) c += subtreeCount(fork.node);
    return c;
}

fn iterNode(
    comptime Ctx: type,
    node: *const Node,
    ctx: Ctx,
    comptime visit: fn (Ctx, []const u8, []const u8) void,
) void {
    visit(ctx, node.entry.key, node.entry.value);
    var f = node.forks;
    while (f) |fork| : (f = fork.next) iterNode(Ctx, fork.node, ctx, visit);
}

// --------------------------------------------------------------------
// Node (de)serialization — wire form of one POT node (one chunk):
//   version:u8=1 | key_len:u16 | key | value_len:u32 | value |
//   fork_count:u8 | fork_count × (po:u16 | child_addr:32)
// All integers little-endian. Children are referenced by chunk address.
// --------------------------------------------------------------------

const ForkRef = struct { po: u16, addr: chunk.Address };

fn serializeNode(buf: []u8, key: []const u8, value: []const u8, refs: []const ForkRef) error{NodeTooLarge}!usize {
    if (key.len > std.math.maxInt(u16)) return error.NodeTooLarge;
    if (value.len > std.math.maxInt(u32)) return error.NodeTooLarge;
    if (refs.len > std.math.maxInt(u8)) return error.NodeTooLarge;
    const need = 1 + 2 + key.len + 4 + value.len + 1 + refs.len * (2 + chunk.HASH_SIZE);
    if (need > buf.len) return error.NodeTooLarge;

    var w: usize = 0;
    buf[w] = 1;
    w += 1;
    std.mem.writeInt(u16, buf[w..][0..2], @intCast(key.len), .little);
    w += 2;
    @memcpy(buf[w..][0..key.len], key);
    w += key.len;
    std.mem.writeInt(u32, buf[w..][0..4], @intCast(value.len), .little);
    w += 4;
    @memcpy(buf[w..][0..value.len], value);
    w += value.len;
    buf[w] = @intCast(refs.len);
    w += 1;
    for (refs) |r| {
        std.mem.writeInt(u16, buf[w..][0..2], r.po, .little);
        w += 2;
        @memcpy(buf[w..][0..chunk.HASH_SIZE], &r.addr);
        w += chunk.HASH_SIZE;
    }
    return w;
}

const ParsedNode = struct { key: []const u8, value: []const u8, refs: []const ForkRef };

fn deserializeNode(payload: []const u8, refs_buf: *[max_forks]ForkRef) error{MalformedNode}!ParsedNode {
    var r: usize = 0;
    if (try readByte(payload, &r) != 1) return error.MalformedNode;
    const key_len = try readU16(payload, &r);
    const key = try readSlice(payload, &r, key_len);
    const value_len = try readU32(payload, &r);
    const value = try readSlice(payload, &r, value_len);
    const fork_count = try readByte(payload, &r);

    var i: usize = 0;
    while (i < @as(usize, fork_count)) : (i += 1) {
        const po = try readU16(payload, &r);
        const addr_bytes = try readSlice(payload, &r, chunk.HASH_SIZE);
        var a: chunk.Address = undefined;
        @memcpy(&a, addr_bytes);
        refs_buf[i] = .{ .po = po, .addr = a };
    }
    return .{ .key = key, .value = value, .refs = refs_buf[0..fork_count] };
}

fn readByte(buf: []const u8, r: *usize) error{MalformedNode}!u8 {
    if (r.* + 1 > buf.len) return error.MalformedNode;
    const v = buf[r.*];
    r.* += 1;
    return v;
}
fn readU16(buf: []const u8, r: *usize) error{MalformedNode}!u16 {
    if (r.* + 2 > buf.len) return error.MalformedNode;
    const v = std.mem.readInt(u16, buf[r.*..][0..2], .little);
    r.* += 2;
    return v;
}
fn readU32(buf: []const u8, r: *usize) error{MalformedNode}!u32 {
    if (r.* + 4 > buf.len) return error.MalformedNode;
    const v = std.mem.readInt(u32, buf[r.*..][0..4], .little);
    r.* += 4;
    return v;
}
fn readSlice(buf: []const u8, r: *usize, n: usize) error{MalformedNode}![]const u8 {
    if (r.* + n > buf.len) return error.MalformedNode;
    const s = buf[r.* .. r.* + n];
    r.* += n;
    return s;
}

// --- canonical save helpers ---

/// A borrowed key/value pair (points into the live tree during `save`).
const EntryRef = struct { key: []const u8, value: []const u8 };

/// Flatten all entries of a node's subtree into `buf` (pre-order).
fn fillEntries(node: *const Node, buf: []EntryRef, idx: *usize) void {
    buf[idx.*] = .{ .key = node.entry.key, .value = node.entry.value };
    idx.* += 1;
    var f = node.forks;
    while (f) |fork| : (f = fork.next) fillEntries(fork.node, buf, idx);
}

/// Sort context: order entries by their proximity order to a pivot key.
const PoCtx = struct {
    pivot: []const u8,
    max_po: usize,
    fn lessThan(ctx: PoCtx, a: EntryRef, b: EntryRef) bool {
        return proximityOrder(ctx.pivot, a.key, ctx.max_po) <
            proximityOrder(ctx.pivot, b.key, ctx.max_po);
    }
};

// --------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------

const testing = std.testing;

test "proximityOrder: differing first bit is 0" {
    try testing.expectEqual(@as(usize, 0), proximityOrder(&[_]u8{0xff}, &[_]u8{0x7f}, 256));
}

test "proximityOrder: differ in last bit of first byte is 7" {
    try testing.expectEqual(@as(usize, 7), proximityOrder(&[_]u8{0xff}, &[_]u8{0xfe}, 256));
}

test "proximityOrder: equal first byte, diff at second byte top bit is 8" {
    try testing.expectEqual(
        @as(usize, 8),
        proximityOrder(&[_]u8{ 0x00, 0xff }, &[_]u8{ 0x00, 0x7f }, 256),
    );
}

test "proximityOrder: identical keys cap at max_po" {
    try testing.expectEqual(@as(usize, 16), proximityOrder(&[_]u8{ 0xaa, 0xbb }, &[_]u8{ 0xaa, 0xbb }, 256));
    try testing.expectEqual(@as(usize, 4), proximityOrder(&[_]u8{ 0xaa, 0xbb }, &[_]u8{ 0xaa, 0xbb }, 4));
}

test "put/get round-trips multiple keys" {
    var idx = Index.init(testing.allocator, 256);
    defer idx.deinit();

    try idx.put("alpha", "1");
    try idx.put("beta", "2");
    try idx.put("gamma", "3");
    try idx.put("delta", "4");

    try testing.expectEqual(@as(usize, 4), idx.count());
    try testing.expectEqualStrings("1", idx.get("alpha").?);
    try testing.expectEqualStrings("2", idx.get("beta").?);
    try testing.expectEqualStrings("3", idx.get("gamma").?);
    try testing.expectEqualStrings("4", idx.get("delta").?);
    try testing.expect(idx.get("missing") == null);
    try testing.expect(!idx.contains("missing"));
}

test "put updates existing key without growing the index" {
    var idx = Index.init(testing.allocator, 256);
    defer idx.deinit();

    try idx.put("k", "old");
    try idx.put("k", "new-and-longer");
    try testing.expectEqual(@as(usize, 1), idx.count());
    try testing.expectEqualStrings("new-and-longer", idx.get("k").?);
}

test "many fixed-length keys survive and are retrievable" {
    var idx = Index.init(testing.allocator, 256);
    defer idx.deinit();

    var key: [4]u8 = undefined;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        std.mem.writeInt(u32, &key, i, .big);
        var val: [8]u8 = undefined;
        const v = std.fmt.bufPrint(&val, "v{d}", .{i}) catch unreachable;
        try idx.put(&key, v);
    }
    try testing.expectEqual(@as(usize, 500), idx.count());

    i = 0;
    while (i < 500) : (i += 1) {
        std.mem.writeInt(u32, &key, i, .big);
        var expect: [8]u8 = undefined;
        const e = std.fmt.bufPrint(&expect, "v{d}", .{i}) catch unreachable;
        try testing.expectEqualStrings(e, idx.get(&key).?);
    }
}

test "delete removes a key, leaves the rest, count drops" {
    var idx = Index.init(testing.allocator, 256);
    defer idx.deinit();

    try idx.put("alpha", "1");
    try idx.put("beta", "2");
    try idx.put("gamma", "3");

    try testing.expect(try idx.delete("beta"));
    try testing.expectEqual(@as(usize, 2), idx.count());
    try testing.expect(idx.get("beta") == null);
    try testing.expectEqualStrings("1", idx.get("alpha").?);
    try testing.expectEqualStrings("3", idx.get("gamma").?);

    // deleting a missing key is a no-op returning false
    try testing.expect(!(try idx.delete("beta")));
    try testing.expectEqual(@as(usize, 2), idx.count());
}

test "delete every key in many orders leaves an empty, leak-free index" {
    var idx = Index.init(testing.allocator, 256);
    defer idx.deinit();

    var key: [4]u8 = undefined;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        std.mem.writeInt(u32, &key, i, .big);
        try idx.put(&key, "x");
    }
    // delete in reverse so survivors get reattached repeatedly
    i = 200;
    while (i > 0) {
        i -= 1;
        std.mem.writeInt(u32, &key, i, .big);
        try testing.expect(try idx.delete(&key));
    }
    try testing.expectEqual(@as(usize, 0), idx.count());

    // still usable afterwards
    try idx.put("again", "ok");
    try testing.expectEqualStrings("ok", idx.get("again").?);
}

const Collector = struct {
    keys: std.StringHashMap(void),
    fn add(self: *Collector, key: []const u8, value: []const u8) void {
        _ = value;
        self.keys.put(key, {}) catch unreachable;
    }
};

test "iterate visits every entry exactly once" {
    var idx = Index.init(testing.allocator, 256);
    defer idx.deinit();

    const keys = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    for (keys) |k| try idx.put(k, "v");

    var c = Collector{ .keys = std.StringHashMap(void).init(testing.allocator) };
    defer c.keys.deinit();
    idx.iterate(&c, Collector.add);

    try testing.expectEqual(@as(usize, keys.len), c.keys.count());
    for (keys) |k| try testing.expect(c.keys.contains(k));
}

// Pull in the other module tests under `zig build test`.
test {
    _ = @import("chunk.zig");
    _ = @import("store.zig");
    _ = @import("bee_store.zig");
}

test "save then load round-trips the whole index via MemStore" {
    var ms = MemStore.init(testing.allocator);
    defer ms.deinit();
    const store = ms.store();

    var src = Index.init(testing.allocator, 256);
    defer src.deinit();
    const keys = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta" };
    for (keys, 0..) |k, i| {
        var vb: [16]u8 = undefined;
        const v = std.fmt.bufPrint(&vb, "val-{d}", .{i}) catch unreachable;
        try src.put(k, v);
    }

    const root = try src.save(store);

    // Determinism: re-saving the same tree yields the same root and adds
    // no new chunks (content-addressed dedup).
    const chunks_after_first = ms.count();
    try testing.expectEqual(root, try src.save(store));
    try testing.expectEqual(chunks_after_first, ms.count());

    var dst = try Index.load(testing.allocator, store, root, 256);
    defer dst.deinit();
    try testing.expectEqual(src.count(), dst.count());
    for (keys, 0..) |k, i| {
        var vb: [16]u8 = undefined;
        const v = std.fmt.bufPrint(&vb, "val-{d}", .{i}) catch unreachable;
        try testing.expectEqualStrings(v, dst.get(k).?);
    }
    try testing.expect(dst.get("absent") == null);
}

test "save on empty index errors; binary key/value survives a round-trip" {
    var ms = MemStore.init(testing.allocator);
    defer ms.deinit();

    var empty = Index.init(testing.allocator, 256);
    defer empty.deinit();
    try testing.expectError(error.EmptyIndex, empty.save(ms.store()));

    var src = Index.init(testing.allocator, 256);
    defer src.deinit();
    try src.put(&[_]u8{ 0, 1, 2, 3 }, &[_]u8{ 0xff, 0x00, 0xaa });
    const root = try src.save(ms.store());

    var dst = try Index.load(testing.allocator, ms.store(), root, 256);
    defer dst.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0x00, 0xaa }, dst.get(&[_]u8{ 0, 1, 2, 3 }).?);
}

test "many keys survive a save/load round-trip" {
    var ms = MemStore.init(testing.allocator);
    defer ms.deinit();

    var src = Index.init(testing.allocator, 256);
    defer src.deinit();
    var key: [4]u8 = undefined;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        std.mem.writeInt(u32, &key, i, .big);
        try src.put(&key, "v");
    }
    const root = try src.save(ms.store());

    var dst = try Index.load(testing.allocator, ms.store(), root, 256);
    defer dst.deinit();
    try testing.expectEqual(@as(usize, 300), dst.count());
    i = 0;
    while (i < 300) : (i += 1) {
        std.mem.writeInt(u32, &key, i, .big);
        try testing.expectEqualStrings("v", dst.get(&key).?);
    }
}

test "canonical save: insertion order does not change the root" {
    const keys = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" };

    var ms1 = MemStore.init(testing.allocator);
    defer ms1.deinit();
    var fwd = Index.init(testing.allocator, 256);
    defer fwd.deinit();
    for (keys) |k| try fwd.put(k, "v");
    const root_fwd = try fwd.save(ms1.store());

    var ms2 = MemStore.init(testing.allocator);
    defer ms2.deinit();
    var rev = Index.init(testing.allocator, 256);
    defer rev.deinit();
    var i: usize = keys.len;
    while (i > 0) {
        i -= 1;
        try rev.put(keys[i], "v");
    }
    const root_rev = try rev.save(ms2.store());

    // Same set → same root, regardless of insertion order, and the two
    // stores hold an identical chunk set.
    try testing.expectEqual(root_fwd, root_rev);
    try testing.expectEqual(ms1.count(), ms2.count());

    // And it still reloads correctly.
    var dst = try Index.load(testing.allocator, ms1.store(), root_fwd, 256);
    defer dst.deinit();
    try testing.expectEqual(@as(usize, keys.len), dst.count());
    for (keys) |k| try testing.expectEqualStrings("v", dst.get(k).?);
}
