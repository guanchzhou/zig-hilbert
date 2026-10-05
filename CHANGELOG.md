# Changelog

## 0.1.0 - 2026-10-05

First release.

### Library

- 2D Hilbert curve driven by compile-time tables (6 levels per lookup,
  32 KiB). Comptime-order and checked runtime-order APIs.
- n-D curve up to 32 dimensions and 128-bit keys (Skilling's transform,
  branch-free, with shift-and-mask bit interleaving).
- Batch encode and decode: structure-of-arrays, interleaved points,
  runtime-order checked batches, and n-D batches. Each takes a thread count
  or a `std.Io`. Threads claim work in blocks, which balances performance
  and efficiency cores.
- Knowledge markers (`hk1`): sortable text keys for embeddings that are
  bit-identical on every platform. Includes range bounds, shared-prefix
  similarity, and `Space.probes` for neighbours across cell boundaries.
- `Space.keys` reports the index of the first failing row.

### Command line

- `key` streams JSON arrays or `{"id", "embedding"}` objects, prints text
  or JSONL, emits probe ranges with `--probe`, limits line length with
  `--max-line`, and reports errors with their line number.
- `range`, `similar`, `cell`, `check`, `encode2`, `decode2`, `version`,
  and `--help`.

### Quality

- Tests against bit-serial and branching reference implementations,
  exhaustive small spaces, fuzz targets, golden marker vectors
  (`test/markers.jsonl`), command-line tests, and compiled examples.
- CI on macOS and Linux in Debug, ReleaseSafe, and ReleaseFast, with fuzzing,
  a performance regression check, and cross-compilation for Linux, Windows,
  wasm32-wasi, and 32-bit ARM. Zig is downloaded with a pinned checksum, and
  actions are pinned to commit SHAs.
