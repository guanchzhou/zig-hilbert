# Changelog

## 0.3.2 - 2026-10-25

- `s2.Cell.fromFacePosLevel` returns `error.InvalidCell` for a face above 5 or a position wider than 61 bits instead of overflowing.
- `s2.Cell.range` and `contains` are safe for id 0 (`fromToken("X")`), whose range holds only itself; `s2.mergeRanges` returns `error.InvalidCell` for an invalid cell. `Cell.level` and `Cell.parent` saturate instead of underflowing on ids and levels outside their domain.
- `s2.cover` returns the new `error.CoverTooLarge`, not `error.BufferTooSmall`, when `min_level` needs more than its 2048-cell expansion queue.
- `hk2.parse` uses the same strict decimal and hex parsing as hk1 markers, rejecting signs, `_` separators, leading zeros and uppercase hex, so it only accepts what `Space.format` writes.
- `hk2.probes` uses at most the first 64 margins, writes just the key for an empty slice, and treats NaN margins as the most certain bits instead of writing past its stack buffers.

## 0.3.1 - 2026-10-20

- Vectorised `hk2.Space.keys` hyperplane projections with 8-lane `@Vector(8, f64)` `@select` accumulation, preserving bit-identical keys and projections.
- Added `hk2.Space.keysBatch` for multi-threaded and `std.Io`-backed batch encoding.
- Added cross-target release workflow (`release.yml`) with `SHA256SUMS`.

## 0.3.0 - 2026-10-07

- `hilbert.hk2`: multi-table angular LSH keys next to hk1. `Space.keys`
  returns one `bits`-bit sign key per table from seeded +-1 hyperplanes, with
  the projections for multi-probe; `probes` lists a table's most likely keys
  in order of the summed |projection| of the flipped bits (Lv et al. 2007).
  Markers are `hk2:<tables>:<bits>:<seed>:<key>.<key>...`, with `format` and
  `parse`. hk1 keys and markers are bit-identical to 0.2.1.
- The `zig-hilbert` command accepts `hk2 [--tables N] [--bits N] [--seed HEX]
  [--probes N]`.

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
