# zig-hilbert

Fast Hilbert curves in pure Zig 0.17, plus sortable Hilbert keys for
embeddings so related notes, documents, and database rows land next to each
other.

- **2D**: 2.7 ns per point at order 32, single core, using a 32 KiB
  compile-time table. That is 10x the classic bit loop, 3.5x Rust
  [`fast_hilbert`](https://github.com/becheran/fast-hilbert), and 37x
  [HilbertCurveCompact](https://github.com/adolgert/HilbertCurveCompact).
  Batches use every core and reach 2.3 billion points per second on a
  10-core M-series Mac.
- **n-D**: up to 32 dimensions and 128-bit keys (Skilling's transform,
  branch-free).
- **Knowledge markers**: a float embedding becomes text such as
  `hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8`. You can store it in a SQL
  column or markdown frontmatter, sort it, and query it with `BETWEEN`.
  Keys are bit-identical on every platform.
- No dependencies, no C, and no heap allocations in the curve functions.
  MIT licensed.

## Install

```sh
zig fetch --save git+https://github.com/guanchzhou/zig-hilbert#v0.1.1
```

```zig
// build.zig
const hilbert = b.dependency("zig_hilbert", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("hilbert", hilbert.module("hilbert"));
```

API documentation: `zig build docs` writes it to `zig-out/docs`, and it is
published at <https://guanchzhou.github.io/zig-hilbert/>.

## Library

These snippets come from [examples/curves.zig](examples/curves.zig) and
[examples/markers.zig](examples/markers.zig), which `zig build test`
compiles and runs.

```zig
// 2D, order known at compile time: no checks, no branches.
const d = hilbert.encode2(16, 12345, 54321); // u64
const p = hilbert.decode2(16, d); // .{ .x, .y }

// 2D, order and coordinates from untrusted input.
const d2 = try hilbert.encode2Checked(16, 12345, 54321);
const p2 = try hilbert.decode2Checked(16, d2);

// Millions of points on every core (threads = 0 means one per core).
try hilbert.batch.encode2(32, xs, ys, out, 0);
try hilbert.batch.decode2(32, out, xs, ys, 0);

// n-D: the index type is exactly dims * bits wide (u24 here).
const k = hilbert.encode(3, 8, .{ 10, 200, 37 });
const pt = hilbert.decode(3, 8, k); // [3]u32
const k2 = try hilbert.encodeChecked(3, 8, &.{ 10, 200, 37 }); // runtime shape, u128

// Walk the curve: consecutive indices, decoded incrementally.
var walk: [256][3]u32 = undefined;
hilbert.decodeRange(3, 8, 1000, &walk); // walk[i] = decode(3, 8, 1000 + i)
```

`decodeRange` (and `decodeRangeChecked` for runtime shapes) reuses the work
of every level above the highest digit that changed, so walking the curve
costs 2-4 ns per point instead of a full decode. Use it to scan a key range
or to fill space in curve order.

`hilbert.batch` also has `encode2Checked` / `decode2Checked` (runtime order,
validated inside the parallel kernel), `encode2Points` / `decode2Points`
(interleaved `[]Point2`), `encode` / `decode` for n-D points, and
`decodeRange` split across threads.

The last argument of every batch function (and of `Space.keys`) is either a
thread count or a `std.Io`. A thread count uses that many OS threads (0
means one per core). A `std.Io` submits the work to that `Io` as a task
group, so your `Io` implementation decides where it runs. That variant can
also return `error.Canceled`.

### Knowledge markers

```zig
var space = try hilbert.Space.init(gpa, .{ .input_dims = 768 }); // dims = 8, bits = 8 by default
defer space.deinit();

const m = try space.marker(&embedding); // []const f32, any magnitude
var buf: [hilbert.Marker.max_len]u8 = undefined;
const text = m.format(&buf); // "hk1:8:8:9e3779b97f4a7c15:..."

const back = try hilbert.Marker.parse(text); // strict: rejects any non-canonical text
const cell = back.range(3); // .lo / .hi bound the cell keeping 3 bits per axis
const shared = hilbert.Marker.sharedPrefixBits(m, try space.marker(&other)); // null if the spaces differ

try space.keys(rows, &keys, 0, null); // many embeddings in parallel; null or *usize for the failing row
```

The marker format is `hk1:<dims>:<bits>:<seed>:<key>`:

- `dims` and `bits` are decimal with no leading zeros. `dims` is 1..32,
  `bits` is 1..32, and `dims * bits` is at most 128.
- `seed` is 16 lowercase hex digits.
- `key` is lowercase hex, zero-padded to `ceil(dims * bits / 4)` digits.
  Within one space, string order equals key order.

A key is computed as follows:

1. Project `e` onto `dims` axes with fixed ±1 signs. The sign of input `i`
   on axis `j` is bit `j` of the `i`-th SplitMix64 output for `seed`
   (negative if set).
2. Divide by `|e|`, so only the direction matters (cosine similarity).
   Scaling `e` by a power of two gives exactly the same key, from tiny
   values up to the largest f32. Other scale factors round differently and
   can, rarely, move a point into the next cell.
3. Map each axis through `1 / (1 + exp(-1.702 z))` into `2^bits` cells.
4. Turn the cell coordinates into one index with the n-D Hilbert curve.

[test/markers.jsonl](test/markers.jsonl) holds 51 embeddings with their
expected markers or errors, including extreme magnitudes. The test suite
reproduces every one bit for bit, so another implementation of `hk1` can
check itself against the same file.

Similar embeddings tend to share long key prefixes. A prefix range is
therefore a cheap candidate filter, which you then rerank with the real
vectors. It is not a nearest-neighbour index on its own.

### Finding neighbours across cell boundaries

A point near the edge of its cell has close neighbours in the next cell,
which a single `range` misses. `Space.probes(embedding, level, out)` returns
the home cell plus the adjacent cells across the boundaries the point is
closest to, sorted and merged, with at most `out.len` ranges.

Here is how often a neighbour with cosine similarity about 0.96 was found
(384-dim embeddings, default 8x8 space, 4000 pairs):

| Level (bits per axis) | 1 range | up to 4 | up to 16 | up to 64 |
|---|---:|---:|---:|---:|
| 1 | 45% | 83% | 96% | 99% |
| 2 | 12% | 30% | 53% | 72% |
| 3 | 1% | 3% | 8% | 15% |

Lower levels keep more candidates per range. Pick the level by how many rows
a cell holds in your data, and the range budget by how much recall you need.

### In a database

Store the marker text in an indexed column, and turn the probe ranges into
one query:

```sql
-- zig-hilbert key --probe 1 --ranges 4 < query.jsonl
SELECT id FROM notes
WHERE marker BETWEEN 'hk1:8:8:9e3779b97f4a7c15:a000000000000000' AND 'hk1:8:8:9e3779b97f4a7c15:a0ffffffffffffff'
   OR marker BETWEEN 'hk1:8:8:9e3779b97f4a7c15:a300000000000000' AND 'hk1:8:8:9e3779b97f4a7c15:a4ffffffffffffff'
   OR marker BETWEEN 'hk1:8:8:9e3779b97f4a7c15:a700000000000000' AND 'hk1:8:8:9e3779b97f4a7c15:a7ffffffffffffff';
```

- **Collation.** `BETWEEN` on text must compare bytes. In PostgreSQL, declare
  the column (or the index) with `COLLATE "C"`. Language-aware collations can
  ignore punctuation and give wrong ranges. SQLite and MySQL `utf8mb4_bin` /
  `ascii_bin` compare bytes already.
- **Integers.** A key can be up to 128 bits, and a 64-bit key above 2^63 does
  not fit a signed `BIGINT`. Store the fixed-width hex text, or the key bytes
  big-endian in `bytea` / `BLOB`. Both sort in key order.

### In markdown

Put the marker in frontmatter. Sorting files by marker groups related notes,
and `grep hk1:8:8:9e3779b97f4a7c15:a0c28a` finds a neighbourhood:

```markdown
---
title: Hilbert curves
hilbert: hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8
---
```

### Privacy

A marker is a coarse, public projection of an embedding, and it includes
the seed, so anyone can recompute the same projection. It reveals roughly
what a document is about, much like a low-resolution embedding. It is not a
secret hash. Do not publish markers of documents whose topic is private.

## Command line

The `zig-hilbert` binary lets scripts, AI tools, and pipelines that are not
written in Zig use the same keys. It streams stdin line by line, so output
starts right away and memory stays flat for any input size.

```sh
zig build -Doptimize=ReleaseFast
$ zig-out/bin/zig-hilbert key < embeddings.jsonl     # one JSON array per line
hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8              # base vector
hk1:8:8:9e3779b97f4a7c15:a0c28ad5a7be0843              # base + 5% noise
hk1:8:8:9e3779b97f4a7c15:717461a5d088a1a5              # unrelated vector
$ zig-out/bin/zig-hilbert similar hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8 hk1:8:8:9e3779b97f4a7c15:a0c28ad5a7be0843
30
$ echo '{"id":"notes/hilbert.md","embedding":[0.1,-1.3,0.8,2.0]}' | zig-out/bin/zig-hilbert key --format jsonl
{"id":"notes/hilbert.md","marker":"hk1:8:8:9e3779b97f4a7c15:bc2c18e5c3700fd5","key":"bc2c18e5c3700fd5","cell":[136,136,213,71,37,119,213,14]}
$ zig-out/bin/zig-hilbert range hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8 3
hk1:8:8:9e3779b97f4a7c15:a0c28a0000000000 hk1:8:8:9e3779b97f4a7c15:a0c28affffffffff
$ zig-out/bin/zig-hilbert cell hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8
182 170 220 181 61 107 111 92
$ zig-out/bin/zig-hilbert check hk1:8:8:XYZ          # exit 1 on invalid markers
$ zig-out/bin/zig-hilbert encode2 16 12345 54321
1555040834
```

- **Input.** Each line of `key` input is a JSON array, or an object with an
  `embedding` array and an optional `id` (string or number). Other fields
  are ignored.
- **Output.** Text output is `MARKER`, or `ID<TAB>MARKER` when the line has
  an id. `--format jsonl` prints `{"id","marker","key","cell"}`, plus
  `"ranges"` with `--probe LEVEL [--ranges N]`.
- **Options.** `--dims`, `--bits`, `--seed HEX` (with or without `0x`), and
  `--threads` choose the space. `--max-line BYTES` (default 4 MiB) limits
  the length of a line.
- **Errors.** They name the input line (`line 4: NonFiniteValue`) and exit
  with code 1. Markers already printed for earlier blocks stay valid.
- **Help.** `zig-hilbert --help` lists every command, and
  `zig-hilbert version` prints the version.

## Performance

Measured on Apple Silicon (10 cores), Zig 0.17.0, ReleaseFast, 8M random
points, median of 9 runs (`zig build bench`):

| Operation | ns/point | vs bit loop |
|---|---:|---:|
| 2D encode, order 32, bit loop (Wikipedia algorithm) | 26.7 | 1.0x |
| 2D encode, order 32, table (default) | 2.69 | 9.9x |
| 2D encode, order 32, batch on all cores | 0.43 | 62x |
| 2D decode, order 32, table | 3.24 | 8.6x |
| 2D encode, order 16, table | 1.01 | 10.0x |
| 2D encode, order 16, batch on all cores | 0.18 | 57x |
| n-D encode, 3 dims x 21 bits | 51 | |
| n-D encode, 8 dims x 8 bits | 55 | |
| n-D encode, 16 dims x 8 bits (128-bit key) | 122 | |
| n-D decode, 3 dims x 21 bits, one index at a time | 47 | |
| n-D `decodeRange`, 3 dims x 21 bits | 2.4 | 20x vs decode |
| n-D `decodeRange`, 8 dims x 8 bits | 2.9 | 17x vs decode |
| n-D `decodeRange`, 16 dims x 8 bits | 3.7 | 26x vs decode |
| Marker key, 768-dim embedding, 1 core | 212 | |
| Marker key, 768-dim embedding, all cores | 38 | |

Why it is fast:

- **Bit loop.** The classic algorithm does 32 dependent iterations per
  point. Each iteration has two data-dependent branches, which mispredict
  on real data.
- **Table.** The curve is a 4-state machine. One lookup in a table
  generated at compile time does 6 levels at once:
  `(state, 6 x-bits, 6 y-bits) -> (state, 12 index bits)`. That is 6 loads
  per point and no branches. The table is 32 KiB, so it stays in the L1
  cache (64-128 KiB per core on Apple Silicon). Independent points overlap
  in the out-of-order core. The 6-bit table is composed from two 3-bit
  tables, so it adds about 0.3 s to a fresh build of a project that uses it.
- **Batch.** Threads claim blocks of work from a shared counter instead of
  equal fixed shares. Performance cores therefore take more blocks than
  efficiency cores, instead of waiting for them.
- **n-D.** Skilling's transform runs branch-free with the per-axis loops
  unrolled at compile time. The index bits are interleaved with
  shift-and-mask spreading, which takes about `5 * dims` operations instead
  of one step per index bit. A chain of dependent operations through the
  first axis limits further speedup.
- **Walking the curve.** Skilling's decode works from the lowest level up,
  but each level's step permutes and complements the axes of every lower
  level the same way, based only on that level's bits. `decodeRange`
  composes those maps from the top down, so the next index only redoes the
  levels below the highest digit that changed, which is one level most of
  the time.
- **Markers.** The projection uses fused multiply-adds, which is exact here
  because every coefficient is -1, 0, or 1. Two rows share each coefficient
  load. The final `exp` and quantization run on all axes at once.

The test suite checks the reasoning, not just the timing:

- Tests in `src/root.zig` assert that an order-32 encode takes exactly 6
  lookups and that the table fits in half of the smallest L1.
- `zig build perf-check` fails if the table drops below 2x the bit loop, or
  if parallel drops below 1.5x a single thread.
- Every table width (1 to 6 bits per lookup) is tested exhaustively against
  the bit-serial reference.

Tried and not adopted:

- A lane-parallel per-bit encoder (`curve2d.encodeLanes`, 9.7 ns at order
  32).
- The branch-free parallel-prefix encoder from
  [Hilbert curves in O(log(n)) time](https://threadlocalmutex.com/?p=126)
  (2016): 5.0 ns scalar and 3.6 ns on 4 NEON lanes at order 32, against
  2.8 ns for the table.

### Comparison

`bench/compare/run.sh` runs every library on one core, with the same points,
the same checksum, and the same median-of-9 timing:

| Library | Language | Encode 32 | Decode 32 | Encode 16 | Decode 16 |
|---|---|---:|---:|---:|---:|
| **zig-hilbert** | Zig 0.17 | **2.67** | **3.22** | **1.00** | **1.43** |
| [fast_hilbert 2.1.0](https://github.com/becheran/fast-hilbert) | Rust | 9.35 | 10.48 | 4.79 | 5.34 |
| [AdamSabol89/fast_hilbert](https://github.com/AdamSabol89/fast_hilbert) | Zig | 7.83 | broken | 4.33 | 10.36 |
| [HilbertCurveCompact](https://github.com/adolgert/HilbertCurveCompact) | Zig 0.14 | 100.0 | 89.8 | 42.8 | 38.4 |

All values are ns/point. All four libraries produce identical indices (equal
checksums), so they compute the same curve.

- **AdamSabol89/fast_hilbert.** At order 32 its `fromHilbert` returns
  coordinates above 2^32 for every one of 1,000,000 points tested, while its
  encoder is correct.
- **HilbertCurveCompact.** It targets Zig 0.14. To build it on 0.17,
  `run.sh` applies `hcc-zig-0.17.patch`, which makes four mechanical syntax
  changes and no algorithm changes. Its batch `encode_points` API runs at
  the same speed (97.6 ns at order 32). It does much more than this library:
  unequal axis extents, other Gray-code families, and arbitrarily wide
  indices. That generality is what the extra time pays for.

#### n-D against HilbertCurveCompact

`run.sh` also runs both libraries on the same 65,536 random n-D points, and
walks the first 65,536 indices with their `decode_range` and our
`decodeRange` (ns/point, one core):

| Space | Encode, theirs | Encode, ours | Decode, theirs | Decode, ours | Consecutive, theirs | Consecutive, ours |
|---|---:|---:|---:|---:|---:|---:|
| 3 x 21 bits | 67.6 | **52.2** | 62.8 | **48.2** | 4.4 | **2.4** |
| 4 x 16 bits | **53.9** | 55.3 | 49.6 | **47.9** | 4.7 | **2.2** |
| 8 x 8 bits | 76.4 | **57.1** | **47.2** | 49.7 | 12.8 | **2.8** |
| 4 x 32 bits | **115.4** | 124.0 | **108.9** | 111.7 | 4.6 | **3.1** |
| 16 x 8 bits | **103.0** | 124.9 | **60.1** | 103.3 | 8.0 | **3.5** |

- **Different curves.** In n-D the two libraries trace different Hilbert
  curves: theirs is built from a rotated reflected Gray code, ours is
  Skilling's. Their indices agreed with ours on 0 of 10,000 random points.
  Both curves are valid. Each library's own round trip is checked.
- **Where we lose.** HilbertCurveCompact is faster at 16 dimensions and
  slightly faster at 4 x 32 bits. Its per-level transition tables pay off
  there, while our transform scales with `dims * bits`.
- **Not compared.** Their tests and benchmarks also cover features this
  library does not have: unequal axis sizes, indices wider than 128 bits,
  more than 32 bits per axis, other Gray-code families, box fills
  (`encode_region` and neighbour traversals), and `compare_points`.

`run.sh` pins every compared library: a crate version with `Cargo.lock` and
`--locked`, a git commit, and a sha256 for the downloaded file.

## Apple Silicon

- **CPU cores.** Batches and marker keys use every performance and
  efficiency core, with dynamic block scheduling. Small inputs stay on one
  thread.
- **NEON.** Marker projection is vectorized with `@Vector`: 8 output axes
  are 2 NEON registers, with fused multiply-adds and 4 independent
  accumulators. The final `exp` and quantization are vectorized too.
- **AMX / Accelerate are not used for marker keys.** BLAS does not specify
  its summation order, so the same note could get different keys on
  different machines or library versions. Keys use a fixed summation order
  and their own `exp` built from IEEE add, multiply, and exponent bits, so a
  marker computed on a Mac matches one computed on Linux x86. The golden
  vectors enforce this in every optimize mode, on arm64 and x86_64.
- **GPU (Metal).** Not in this version. At 0.2-0.4 ns/point on the CPU,
  copying data to the GPU and back costs more than the encode itself, for
  batches that fit in memory.
- **Neural Engine.** It runs neural networks, so it is where you would
  *produce* embeddings (Core ML). It cannot run this integer and bit
  arithmetic.

## Safety

- **Checked APIs.** They validate order, coordinates, and indices and return
  errors. The comptime APIs mask their inputs, so out-of-range bits can
  never index outside a table.
- **Strict parsing.** `Marker.parse` accepts only canonical text: lowercase
  hex, exact widths, no leading zeros, and keys inside the space. One key
  therefore has exactly one spelling.
- **Marker input checks.** Marker keys reject NaN, infinity, and zero
  vectors, and limit inputs to 65536 dimensions. Vectors whose squared norm
  would overflow or underflow an f32 are rescaled exactly instead of being
  rejected.
- **CLI limits.** The CLI limits line length, bounds memory by processing
  blocks of rows, and reports errors on stderr with exit code 1.
- **Testing.** Tests run in Debug, ReleaseSafe, and ReleaseFast. The checked
  APIs and the marker parser have fuzz targets, the n-D curve is checked
  against Skilling's original branching algorithm, and the CLI has its own
  test suite.
- **CI supply chain.** CI downloads Zig from ziglang.org with a pinned
  sha256 and pins every action to a commit SHA.

## Development

```sh
zig build test              # unit, golden, example, and command-line tests
zig build test-cli          # command-line tests only
zig build test --fuzz       # fuzz the parser and checked APIs (--fuzz=1M for a fixed budget)
zig build bench             # full benchmark (always ReleaseFast)
zig build perf-check        # quick benchmark that fails on regressions
zig build docs              # API documentation in zig-out/docs
zig build golden            # regenerate test/markers.jsonl (marker format changes only)
bench/compare/run.sh        # cross-library comparison (needs cargo, git, curl)
```

## Credits

- The 2D reference implementation (`src/reference.zig`) is the iterative
  algorithm from [Wikipedia: Hilbert curve](https://en.wikipedia.org/wiki/Hilbert_curve).
- The n-D curve and its reference implementation use the transpose method
  from J. Skilling, "Programming the Hilbert curve", *AIP Conference
  Proceedings* 707, 381 (2004), <https://doi.org/10.1063/1.1751381>.

### Related work

[HilbertCurveCompact](https://github.com/adolgert/HilbertCurveCompact) is
used here as a benchmark baseline only; no code or ideas were taken from it.
Its compact, unequal-extent construction is described in:

```bibtex
@misc{dolgert2026hilbert,
  author    = {Dolgert, Andrew},
  title     = {Gluing the Seam of a Hilbert Curve},
  year      = {2026},
  publisher = {Carnegie Mellon University},
  note      = {Preprint},
  doi       = {10.1184/R1/32104066.v1},
  url       = {https://doi.org/10.1184/R1/32104066.v1}
}
```

## License

MIT. See [LICENSE](LICENSE).
