# zigpot

A **Proximity Order Trie (POT)** for [Swarm](https://www.ethswarm.org/),
written in Zig — a mutable, content-addressable key/value index that
(once Phase 2 lands) persists on Swarm. A Zig take on
[`ethersphere/proximity-order-trie`](https://github.com/ethersphere/proximity-order-trie),
sibling to the Rust/Go/Py/TS clients under
[ethswarm-tools](https://github.com/ethswarm-tools).

A POT organizes entries by the **proximity order** of their keys — the
position of the first bit that differs from a node's pivot key — so
lookups branch on PO instead of one bit/byte at a time, and depth is
bounded by key-bit length.

## Status

- **Phase 1 — in-memory core: done.** `proximityOrder` + a mutable
  `Index` with `put` / `get` / `contains` / `delete` / `iterate` /
  `count`.
- **Phase 2 — Swarm persistence: done.** BMT/keccak256 chunk addressing
  (vector-checked against bee-rs/bee-go, so a Bee node accepts the
  chunks), one-chunk-per-node serialization, and `Index.save` / `load`
  through a pluggable `Store`. `MemStore` (in-memory, content-addressed,
  deduping) and `BeeStore` (`POST`/`GET /chunks` with the postage-batch
  header) ship today. The root chunk address is the database handle.
  *(Verified live against a Bee node — Sepolia testnet, Bee 2.7.2: keys
  uploaded with a postage stamp via `POST /chunks` and read back via
  `GET /chunks`.)*
- **Phase 3 — CLI: done.** `put` / `get` / `del` / `list` over a local
  `--dir` store or a `--bee` node; the printed root chunk address is the
  database handle you thread back with `--root`. `demo` runs in-memory.

26 tests, leak-checked, `zig fmt` clean (`zig build test`). Built for
**Zig 0.16**. Canonical save (same key/value set → same root) and a
`walkStructure` introspection API (used by zigpot-tui) are included.

## CLI

```sh
zig build                       # builds ./zig-out/bin/zigpot
zigpot put name ada --dir ./db          # → prints root1
zigpot put lang zig --root <root1> --dir ./db   # → prints root2
zigpot get name      --root <root2> --dir ./db  # → ada
zigpot list          --root <root2> --dir ./db
zigpot del lang      --root <root2> --dir ./db  # → root back to {name}
```

Swap `--dir <path>` for `--bee <url> [--stamp <batch>]` (or `$BEE_BATCH_ID`)
to persist on Swarm instead of local disk. Mutations are content-addressed,
so the same logical contents always produce the same root.

## Build & test

```sh
zig build test     # run the unit tests
zig build run      # run the demo
```

Requires Zig 0.15.x.

## Library use

```zig
const zigpot = @import("zigpot");

var idx = zigpot.Index.init(allocator, 256); // 256 = max proximity order
defer idx.deinit();

try idx.put("hello", "world");
const v = idx.get("hello");        // ?[]const u8
_ = try idx.delete("hello");       // bool
```

## License

MIT (see `LICENSE-MIT`). Dual MIT OR Apache-2.0 to match the sibling
crates will be finalized before any release.
