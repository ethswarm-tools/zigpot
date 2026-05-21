# Go-POT interoperability (status & plan)

Goal: make zigpot produce **byte-identical roots** to the Go reference
[`ethersphere/proximity-order-trie`](https://github.com/ethersphere/proximity-order-trie),
so a POT written by one can be read by the other.

**Status: not yet implemented.** zigpot uses its own (simpler, zero-dep)
chunk format and addressing. This document is the spec for a future
`go-compat` mode, derived from reading the Go source.

## What the Go impl does

**Node serialization** (`pkg/elements/persist.go`, `SwarmNode.MarshalBinary`):

```
key       32 bytes              (MUST be exactly 32 — Swarm-hashed keys)
bitmap    32 bytes              256-bit map: bit (7-po%8) of byte po/8 set per fork PO
forkRefs  c × 32 bytes          child references, in ascending-PO order
forkSizes c × 4 bytes (BE u32)  subtree element count per fork,
                                then zero-padded up to a 32-byte boundary
value     variable              the Entry's MarshalBinary
```

**Addressing** (`pkg/persister/swarm.go`, `Save`): nodes are POSTed to
**`/bytes`** (the Swarm *file* API), not `/chunks`. The returned 32-byte
reference is therefore a Swarm bytes-reference: for data ≤ 4096 it equals
the single chunk's BMT address, but larger nodes are split into a binary
Merkle tree of chunks and the reference is the tree root.

**Structure** (`pkg/elements/ops.go`, `Update`/`update`): the tree shape
is produced by the recursive update algorithm; matching root hashes
requires reproducing its pivot selection exactly (this differs from
zigpot's current "lexicographically smallest pivot" canonicalization).

## Gaps vs zigpot today

| Aspect | zigpot now | Go-compat needs |
|---|---|---|
| Key length | arbitrary | exactly 32 bytes |
| Node layout | `ver│klen│k│vlen│v│nforks│(po:u16,ref)` | `key│bitmap│refs│sizes│value` |
| Fork index | per-fork `po:u16` | 256-bit bitmap |
| Subtree sizes | not stored | `c × u32` (BE), 32-padded |
| Addressing | `/chunks` (single-chunk BMT) | `/bytes` (Swarm binary-Merkle file hash) |
| Pivot rule | smallest-key canonical | Go `update` algorithm |
| Value | raw bytes | `Entry.MarshalBinary` |

## Implementation plan

1. **Swarm file hasher** — implement the binary Merkle tree over chunks
   (span + 4096-byte branching, BMT per chunk) so node refs match
   `/bytes`. (For ≤4 KB nodes this reduces to the existing
   `chunk.chunkAddress`, so start there and add the intermediate-tree
   levels.)
2. **`go-compat` serializer** — a second `serializeNode`/`deserializeNode`
   pair matching the layout above, gated behind a mode flag; require
   32-byte keys in this mode.
3. **Subtree sizes** — track element counts per node (already have `len`;
   add per-fork counts during canonical save).
4. **Structure** — port Go's `update` pivot rule (or confirm Go's form is
   reproducible from the smallest-key canonical form; verify empirically).
5. **`BeeStore` `/bytes` path** — add upload/download via `/bytes` for the
   compat mode.

## Verification

The Go impl is available locally at
`~/work/swarm/hackathon/proximity-order-trie`. Plan: write a tiny Go
program that builds a POT from a fixed 32-byte-key dataset and prints the
root, then assert zigpot's `go-compat` save of the same dataset yields the
identical root (and that Go can `Find` keys zigpot wrote, and vice versa,
against a running Bee node).

Until this lands, zigpot's roots are self-consistent and canonical
**within zigpot**, but not byte-compatible with the Go reference.
