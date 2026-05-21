//! zigpot CLI — a content-addressed key/value store on Swarm (or local
//! disk). The root chunk address is your database handle: every mutation
//! prints the new root, which you pass back via `--root` next time.
//!
//!   zigpot put  <key> <value> [--root <ref>]  (--dir <path> | --bee <url> [--stamp <batch>])
//!   zigpot get  <key> --root <ref>            (--dir <path> | --bee <url>)
//!   zigpot del  <key> --root <ref>            (--dir <path> | --bee <url> [--stamp <batch>])
//!   zigpot list        --root <ref>           (--dir <path> | --bee <url>)
//!   zigpot demo
//!
//! `--bee` uploads require a postage batch (--stamp <batch>).

const std = @import("std");
const zigpot = @import("zigpot");

const Command = enum { put, get, del, list, demo, help };

const Backend = union(enum) {
    dir: []const u8,
    bee: struct { url: []const u8, stamp: ?[]const u8 },
};

const Args = struct {
    cmd: Command,
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
    root: ?[]const u8 = null,
    backend: ?Backend = null,
};

const max_po = 256;

fn parseCommand(s: []const u8) ?Command {
    const map = .{
        .{ "put", Command.put },     .{ "get", Command.get },
        .{ "del", Command.del },     .{ "delete", Command.del },
        .{ "list", Command.list },   .{ "ls", Command.list },
        .{ "demo", Command.demo },   .{ "help", Command.help },
        .{ "--help", Command.help }, .{ "-h", Command.help },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, s, m[0])) return m[1];
    }
    return null;
}

fn parseArgs(argv: []const []const u8) !Args {
    if (argv.len < 2) return Args{ .cmd = .help };
    const cmd = parseCommand(argv[1]) orelse return error.UnknownCommand;
    var out = Args{ .cmd = cmd };

    var dir: ?[]const u8 = null;
    var bee_url: ?[]const u8 = null;
    var bee_stamp: ?[]const u8 = null;
    var pos: [2][]const u8 = undefined;
    var npos: usize = 0;

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (flagValue(argv, &i, a, "--root")) |v| {
            out.root = v;
        } else if (flagValue(argv, &i, a, "--dir")) |v| {
            dir = v;
        } else if (flagValue(argv, &i, a, "--bee")) |v| {
            bee_url = v;
        } else if (flagValue(argv, &i, a, "--stamp")) |v| {
            bee_stamp = v;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownFlag;
        } else {
            if (npos >= pos.len) return error.TooManyArguments;
            pos[npos] = a;
            npos += 1;
        }
    }

    if (npos >= 1) out.key = pos[0];
    if (npos >= 2) out.value = pos[1];
    if (dir) |d| {
        out.backend = .{ .dir = d };
    } else if (bee_url) |u| {
        out.backend = .{ .bee = .{ .url = u, .stamp = bee_stamp } };
    }
    return out;
}

/// If `a == name`, consume the next argv entry as its value (advancing
/// `i`), else null. Errors surface as a missing value at call sites.
fn flagValue(argv: []const []const u8, i: *usize, a: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, a, name)) return null;
    if (i.* + 1 >= argv.len) return null; // treated as no value → caller may error later
    i.* += 1;
    return argv[i.*];
}

/// Context for `list` iteration: writes rows, capturing any write error.
const ListWriter = struct {
    out: *std.Io.Writer,
    err: ?anyerror = null,
    fn visit(self: *ListWriter, key: []const u8, value: []const u8) void {
        self.out.print("{s}\t{s}\n", .{ key, value }) catch |e| {
            self.err = e;
        };
    }
};

/// Run a command against an already-resolved store. Returns the process
/// exit code (0 ok, 1 = get miss). Pure of argv/stdout wiring → testable.
fn execute(allocator: std.mem.Allocator, store: zigpot.Store, args: Args, out: *std.Io.Writer) !u8 {
    var idx = if (args.root) |rhex| blk: {
        var addr: zigpot.Address = undefined;
        _ = std.fmt.hexToBytes(&addr, rhex) catch return error.BadRootHex;
        break :blk try zigpot.Index.load(allocator, store, addr, max_po);
    } else zigpot.Index.init(allocator, max_po);
    defer idx.deinit();

    switch (args.cmd) {
        .put => {
            const key = args.key orelse return error.MissingKey;
            const value = args.value orelse return error.MissingValue;
            try idx.put(key, value);
            try out.print("{s}\n", .{zigpot.toHex(try idx.save(store))[0..]});
        },
        .get => {
            const key = args.key orelse return error.MissingKey;
            if (idx.get(key)) |v| {
                try out.print("{s}\n", .{v});
            } else {
                return 1;
            }
        },
        .del => {
            const key = args.key orelse return error.MissingKey;
            _ = try idx.delete(key);
            if (idx.count() == 0) {
                try out.print("(empty)\n", .{});
            } else {
                try out.print("{s}\n", .{zigpot.toHex(try idx.save(store))[0..]});
            }
        },
        .list => {
            var lw = ListWriter{ .out = out };
            idx.iterate(&lw, ListWriter.visit);
            if (lw.err) |e| return e;
        },
        .demo, .help => unreachable,
    }
    return 0;
}

fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, out: *std.Io.Writer) !u8 {
    const args = try parseArgs(argv);
    switch (args.cmd) {
        .help => {
            try printUsage(out);
            return 0;
        },
        .demo => {
            try runDemo(allocator, out);
            return 0;
        },
        else => {},
    }

    const backend = args.backend orelse {
        try out.print("error: choose a backend: --dir <path> or --bee <url>\n", .{});
        return 2;
    };
    return switch (backend) {
        .dir => |path| blk: {
            var fs_store = try zigpot.FileStore.init(io, path);
            defer fs_store.deinit();
            break :blk try execute(allocator, fs_store.store(), args, out);
        },
        .bee => |b| blk: {
            var bee = zigpot.BeeStore.init(io, allocator, b.url, b.stamp);
            defer bee.deinit();
            break :blk try execute(allocator, bee.store(), args, out);
        },
    };
}

fn printUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\zigpot — a content-addressed key/value store on Swarm (or local disk).
        \\
        \\Usage:
        \\  zigpot put  <key> <value> [--root <ref>]  (--dir <path> | --bee <url> [--stamp <batch>])
        \\  zigpot get  <key> --root <ref>            (--dir <path> | --bee <url>)
        \\  zigpot del  <key> --root <ref>            (--dir <path> | --bee <url> [--stamp <batch>])
        \\  zigpot list        --root <ref>           (--dir <path> | --bee <url>)
        \\  zigpot demo
        \\
        \\The root chunk address printed by put/del is the database handle;
        \\pass it back with --root. Uploads need a postage batch (--stamp <batch>).
        \\
    );
}

fn runDemo(allocator: std.mem.Allocator, out: *std.Io.Writer) !void {
    var idx = zigpot.Index.init(allocator, max_po);
    defer idx.deinit();
    try idx.put("hello", "world");
    try idx.put("swarm", "bee");
    try idx.put("hello", "there");
    try out.print(
        "demo: {d} entries · hello -> {s} · swarm -> {s}\n",
        .{ idx.count(), idx.get("hello").?, idx.get("swarm").? },
    );
}

pub fn main() void {
    const allocator = std.heap.page_allocator;

    const raw = std.process.argsAlloc(allocator) catch {
        std.process.exit(1);
    };
    defer std.process.argsFree(allocator, raw);

    // Coerce [][:0]u8 → [][]const u8 for parsing.
    const argv = allocator.alloc([]const u8, raw.len) catch std.process.exit(1);
    defer allocator.free(argv);
    for (raw, 0..) |a, i| argv[i] = a;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;

    const code = run(allocator, io, argv, out) catch |e| {
        out.flush() catch {};
        std.debug.print("zigpot: error: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    out.flush() catch {};
    std.process.exit(code);
}

// --------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------

const testing = std.testing;

test "parseArgs: backend, flags, positionals" {
    const a = try parseArgs(&.{ "zigpot", "put", "k", "v", "--dir", "/tmp/db" });
    try testing.expectEqual(Command.put, a.cmd);
    try testing.expectEqualStrings("k", a.key.?);
    try testing.expectEqualStrings("v", a.value.?);
    try testing.expectEqualStrings("/tmp/db", a.backend.?.dir);

    const b = try parseArgs(&.{ "zigpot", "get", "k", "--root", "ab12", "--bee", "http://n:1633" });
    try testing.expectEqual(Command.get, b.cmd);
    try testing.expectEqualStrings("ab12", b.root.?);
    try testing.expectEqualStrings("http://n:1633", b.backend.?.bee.url);

    try testing.expectError(error.UnknownCommand, parseArgs(&.{ "zigpot", "frobnicate" }));
    try testing.expectEqual(Command.help, (try parseArgs(&.{"zigpot"})).cmd);
}

test "CLI end-to-end via a FileStore: put -> root -> get/list/del" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = ".zigpot-clitest";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {}; // clean slate
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // put "name"="ada" (no root → fresh db); capture the printed root
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const code1 = try run(testing.allocator, io, &.{ "zigpot", "put", "name", "ada", "--dir", dir }, &aw.writer);
    try testing.expectEqual(@as(u8, 0), code1);
    const root1 = std.mem.trim(u8, aw.written(), "\n");
    try testing.expectEqual(@as(usize, 64), root1.len);

    // put a second key, threading the first root in
    var aw2 = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw2.deinit();
    _ = try run(testing.allocator, io, &.{ "zigpot", "put", "lang", "zig", "--root", root1, "--dir", dir }, &aw2.writer);
    const root2 = std.mem.trim(u8, aw2.written(), "\n");

    // get both keys back from root2
    var g = std.Io.Writer.Allocating.init(testing.allocator);
    defer g.deinit();
    try testing.expectEqual(@as(u8, 0), try run(testing.allocator, io, &.{ "zigpot", "get", "name", "--root", root2, "--dir", dir }, &g.writer));
    try testing.expectEqualStrings("ada\n", g.written());

    // a missing key exits 1
    var miss = std.Io.Writer.Allocating.init(testing.allocator);
    defer miss.deinit();
    try testing.expectEqual(@as(u8, 1), try run(testing.allocator, io, &.{ "zigpot", "get", "absent", "--root", root2, "--dir", dir }, &miss.writer));

    // list shows both rows
    var l = std.Io.Writer.Allocating.init(testing.allocator);
    defer l.deinit();
    _ = try run(testing.allocator, io, &.{ "zigpot", "list", "--root", root2, "--dir", dir }, &l.writer);
    try testing.expect(std.mem.indexOf(u8, l.written(), "name\tada") != null);
    try testing.expect(std.mem.indexOf(u8, l.written(), "lang\tzig") != null);

    // delete one key, then it's gone
    var d = std.Io.Writer.Allocating.init(testing.allocator);
    defer d.deinit();
    _ = try run(testing.allocator, io, &.{ "zigpot", "del", "lang", "--root", root2, "--dir", dir }, &d.writer);
    const root3 = std.mem.trim(u8, d.written(), "\n");
    var g2 = std.Io.Writer.Allocating.init(testing.allocator);
    defer g2.deinit();
    try testing.expectEqual(@as(u8, 1), try run(testing.allocator, io, &.{ "zigpot", "get", "lang", "--root", root3, "--dir", dir }, &g2.writer));
}
