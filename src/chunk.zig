//! Swarm content-addressed chunk addressing: BMT over keccak256.
//!
//! A Swarm chunk is `span (8-byte little-endian u64) || payload (≤4096)`.
//! Its address is `keccak256(span || bmt_root(zero_padded_payload))`,
//! where `bmt_root` is a binary Merkle tree that keccak-pair-reduces the
//! 128 32-byte segments of the full 4096-byte payload region.
//!
//! This must match Bee exactly — a node rejects a POSTed chunk whose
//! address doesn't equal the BMT of its content. Pinned in tests to the
//! bee-rs/bee-go vector for "hello world".

const std = @import("std");
const Keccak256 = std.crypto.hash.sha3.Keccak256;

pub const CHUNK_SIZE: usize = 4096;
pub const SEGMENT_SIZE: usize = 32;
pub const SEGMENTS: usize = CHUNK_SIZE / SEGMENT_SIZE; // 128
pub const SPAN_SIZE: usize = 8;
pub const HASH_SIZE: usize = 32;
pub const Address = [HASH_SIZE]u8;

fn keccakParts(parts: []const []const u8) Address {
    var h = Keccak256.init(.{});
    for (parts) |p| h.update(p);
    var out: Address = undefined;
    h.final(&out);
    return out;
}

/// keccak256 of a byte slice.
pub fn keccak256(input: []const u8) Address {
    return keccakParts(&.{input});
}

/// Binary-Merkle-tree root of up to `CHUNK_SIZE` bytes (zero-padded to
/// 128 segments), keccak-pair-reduced to a single 32-byte root.
pub fn bmtRoot(payload: []const u8) Address {
    std.debug.assert(payload.len <= CHUNK_SIZE);
    var buf = [_]u8{0} ** CHUNK_SIZE;
    @memcpy(buf[0..payload.len], payload);

    var level: [SEGMENTS]Address = undefined;
    var i: usize = 0;
    while (i < SEGMENTS) : (i += 1) {
        @memcpy(level[i][0..], buf[i * SEGMENT_SIZE .. i * SEGMENT_SIZE + SEGMENT_SIZE]);
    }

    var n: usize = SEGMENTS;
    while (n > 1) : (n /= 2) {
        var j: usize = 0;
        while (j < n / 2) : (j += 1) {
            level[j] = keccakParts(&.{ level[2 * j][0..], level[2 * j + 1][0..] });
        }
    }
    return level[0];
}

/// Content-addressed chunk address of a payload: the span is the
/// payload length. `payload` must be ≤ `CHUNK_SIZE`.
pub fn chunkAddress(payload: []const u8) Address {
    std.debug.assert(payload.len <= CHUNK_SIZE);
    var span: [SPAN_SIZE]u8 = undefined;
    std.mem.writeInt(u64, &span, @as(u64, @intCast(payload.len)), .little);
    const root = bmtRoot(payload);
    return keccakParts(&.{ span[0..], root[0..] });
}

/// Encode the on-the-wire chunk bytes (`span || payload`) for upload.
/// Caller owns the returned buffer.
pub fn encodeChunk(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    std.debug.assert(payload.len <= CHUNK_SIZE);
    const out = try allocator.alloc(u8, SPAN_SIZE + payload.len);
    std.mem.writeInt(u64, out[0..SPAN_SIZE], @as(u64, @intCast(payload.len)), .little);
    @memcpy(out[SPAN_SIZE..], payload);
    return out;
}

/// Lowercase hex of an address.
pub fn toHex(addr: Address) [HASH_SIZE * 2]u8 {
    return std.fmt.bytesToHex(addr, .lower);
}

// --------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------

const testing = std.testing;

test "keccak256 of empty string is the well-known value" {
    const hex = toHex(keccak256(""));
    try testing.expectEqualStrings(
        "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        &hex,
    );
}

test "chunk address of 'hello world' matches bee-rs/bee-go vector" {
    const hex = toHex(chunkAddress("hello world"));
    try testing.expectEqualStrings(
        "92672a471f4419b255d7cb0cf313474a6f5856fb347c5ece85fb706d644b630f",
        &hex,
    );
}

test "addressing is deterministic and span-sensitive" {
    try testing.expectEqual(chunkAddress("abc"), chunkAddress("abc"));
    try testing.expect(!std.mem.eql(u8, &chunkAddress("abc"), &chunkAddress("abcd")));
}

test "encodeChunk lays out span then payload" {
    const wire = try encodeChunk(testing.allocator, "test");
    defer testing.allocator.free(wire);
    try testing.expectEqual(@as(usize, SPAN_SIZE + 4), wire.len);
    try testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, wire[0..SPAN_SIZE], .little));
    try testing.expectEqualStrings("test", wire[SPAN_SIZE..]);
}
