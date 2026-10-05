# Changelog

## 0.2.1 - 2026-10-05

- `hilbert.s2.cover`, `coverCap`, `coverPolyline`, and `coverPolygon` cover
  a disk, a polyline, a simple polygon, or a caller-defined region with
  cells. `mergeRanges` turns those cells into inclusive id ranges.
  `covering` is unchanged.
- The `zig-hilbert` command accepts `s2-token`, `s2-cover`, `s2-polyline`,
  and `s2-polygon`.
- CI fuzzes on Linux as well as macOS. The fuzzer needs LLVM's coverage
  instrumentation, so that job builds with `-Dllvm=true`.

## 0.2.0 - 2026-10-05

- `decodeRange` and `decodeRangeChecked` decode consecutive n-D indices
  incrementally: 2-4 ns per point, 17-26x faster than decoding each index.
  `batch.decodeRange` splits a walk across threads or a `std.Io`, and
  returns `error.IndexOutOfRange` when the walk would leave the space.
- `batch.decode2PointsChecked` decodes interleaved 2D points at a runtime
  order, validating indices inside the parallel kernel.
- S2 cell ids (`hilbert.s2`): latitude and longitude become the same u64
  cell ids as Google's S2 library, including parent, children, edge
  neighbours, hex tokens, and a cap covering that returns merged id ranges.
- `bench/compare/run.sh` compares n-D encode, decode, and consecutive
  decode with HilbertCurveCompact.
- Fuzz targets replay the corpus in `src/fuzz-corpus/` on every `zig build test`.

## 0.1.1 - 2026-10-05

- Fix: the package omitted `test/` and `examples/`, which `build.zig`
  needs, so projects that depend on 0.1.0 failed to build. CI now builds a
  consumer project from the packaged archive.

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
