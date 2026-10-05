# zig-hilbert

Fast Hilbert curves in pure Zig 0.17, plus sortable Hilbert keys for
embeddings so related notes, documents, and database rows land next to each
other.

- **2D**: 2.4 ns per point at order 32, single core, using a 32 KiB
  compile-time table. That is 10x the classic bit loop, 3.5x Rust
  [`fast_hilbert`](https://github.com/becheran/fast-hilbert), and 39x
  [HilbertCurveCompact](https://github.com/adolgert/HilbertCurveCompact).
  Batches use every core and reach 2.3 billion points per second on a
  10-core M-series Mac.
- **n-D**: up to 32 dimensions and 128-bit keys (Skilling's transform, branch-free).
- **Knowledge markers**: a float embedding becomes text such as
  `hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8`. You can store it in a SQL
  column or markdown frontmatter, sort it, and query it with `BETWEEN`.
  Keys are bit-identical on every platform.
- No dependencies, no C, and no heap allocations in the curve functions.
  MIT licensed.

## Install

```sh
zig fetch --save git+https://github.com/guanchzhou/zig-hilbert
```

```zig
// build.zig
const hilbert = b.dependency("zig_hilbert", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("hilbert", hilbert.module("hilbert"));
```

## Library

```zig
const hilbert = @import("hilbert");

// 2D, order known at compile time: no checks, no branches.
const d = hilbert.encode2(16, x, y); // u64
const p = hilbert.decode2(16, d); // .{ .x, .y }

// 2D, order and coordinates from untrusted input.
const d2 = try hilbert.encode2Checked(order, x, y); // error.OrderOutOfRange, error.CoordinateOutOfRange
const p2 = try hilbert.decode2Checked(order, d2); // error.IndexOutOfRange

// Millions of points on every core (threads = 0 means one per core).
try hilbert.batch.encode2(32, xs, ys, out, 0);
try hilbert.batch.decode2(32, out, xs, ys, 0);

// n-D: the index type is exactly dims * bits wide (u24 here).
const k = hilbert.encode(3, 8, .{ 10, 200, 37 });
const pt = hilbert.decode(3, 8, k); // [3]u32
const k2 = try hilbert.encodeChecked(dims, bits, coords); // runtime shape, u128
```

### Knowledge markers

```zig
var space = try hilbert.Space.init(gpa, .{ .input_dims = 768 }); // dims = 8, bits = 8 by default
defer space.deinit();

const m = try space.marker(embedding); // []const f32, any scale
var buf: [hilbert.Marker.max_len]u8 = undefined;
const text = m.format(&buf); // "hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8"

const back = try hilbert.Marker.parse(text); // strict: rejects any non-canonical text
const cell = back.range(3); // .lo / .hi bound the cell keeping 3 bits per axis
const shared = hilbert.Marker.sharedPrefixBits(m, other); // null if the spaces differ

try space.keys(rows, keys_out, 0); // many embeddings in parallel
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
3. Map each axis through `1 / (1 + exp(-1.702 z))` into `2^bits` cells.
4. Turn the cell coordinates into one index with the n-D Hilbert curve.

Similar embeddings tend to share long key prefixes. A prefix range is
therefore a cheap candidate filter, which you then rerank with the real
vectors. It is not a nearest-neighbour index on its own.

**In a database**, store the marker text (or the key as an integer) in an
indexed column and scan one cell:

```sql
-- zig-hilbert range hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8 3
SELECT id FROM notes
WHERE marker BETWEEN 'hk1:8:8:9e3779b97f4a7c15:a0c28a0000000000'
                 AND 'hk1:8:8:9e3779b97f4a7c15:a0c28affffffffff';
```

**In markdown**, put it in frontmatter. Sorting files by marker groups
related notes, and `grep hk1:8:8:9e3779b97f4a7c15:a0c28a` finds a
neighbourhood:

```markdown
---
title: Hilbert curves
hilbert: hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8
---
```

## Command line

The `zig-hilbert` binary lets scripts, AI tools, and pipelines that are not
written in Zig use the same keys. It reads JSON arrays on stdin and writes
text on stdout.

```sh
zig build -Doptimize=ReleaseFast
$ zig-out/bin/zig-hilbert key < embeddings.jsonl     # one JSON array per line
hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8              # base vector
hk1:8:8:9e3779b97f4a7c15:a0c28ad5a7be0843              # base + 5% noise: shares 30 bits
hk1:8:8:9e3779b97f4a7c15:717461a5d088a1a5              # unrelated vector
$ zig-out/bin/zig-hilbert range hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8 3
hk1:8:8:9e3779b97f4a7c15:a0c28a0000000000 hk1:8:8:9e3779b97f4a7c15:a0c28affffffffff
$ zig-out/bin/zig-hilbert check hk1:8:8:XYZ          # exit 1 on invalid markers
$ zig-out/bin/zig-hilbert encode2 16 12345 54321
1555040834
```

`key` also accepts `--dims`, `--bits`, `--seed HEX`, and `--threads`.

## Performance

Measured on Apple Silicon (10 cores), Zig 0.17.0, ReleaseFast, 8M random
points, median of 9 runs (`zig build bench`):

| Operation | ns/point | vs bit loop |
|---|---:|---:|
| 2D encode, order 32, bit loop (Wikipedia algorithm) | 24.9 | 1.0x |
| 2D encode, order 32, table (default) | 2.46 | 10.2x |
| 2D encode, order 32, batch on all cores | 0.44 | 57x |
| 2D decode, order 32, table | 2.99 | 8.7x |
| 2D encode, order 16, table | 0.96 | 9.7x |
| 2D encode, order 16, batch on all cores | 0.20 | 48x |
| n-D encode, 3 dims x 21 bits | 65 | |
| n-D encode, 8 dims x 8 bits | 61 | |
| Marker key, 768-dim embedding, 1 core | 476 | |
| Marker key, 768-dim embedding, all cores | 87 | |

Why the table is faster:

- **Bit loop.** The classic algorithm does 32 dependent iterations per
  point. Each iteration has two data-dependent branches, which mispredict
  on real data.
- **Table.** The curve is a 4-state machine. One lookup in a table
  generated at compile time does 6 levels at once:
  `(state, 6 x-bits, 6 y-bits) -> (state, 12 index bits)`. That is 6 loads
  per point and no branches. The table is 32 KiB, so it stays in the L1
  cache (64-128 KiB per core on Apple Silicon). Independent points overlap
  in the out-of-order core.
- **Batch.** The same kernel split across all performance and efficiency
  cores.

The test suite checks the reasoning, not just the timing. Tests in
`src/root.zig` assert that an order-32 encode takes exactly 6 lookups and
that the table fits in half of the smallest L1. `zig build perf-check`
fails if the table drops below 2x the bit loop, or if parallel drops below
1.5x a single thread. Every table width (1 to 6 bits per lookup) is tested
exhaustively against the bit-serial reference.

### Comparison

`bench/compare/run.sh` runs every library on one core, with the same points,
the same checksum, and the same median-of-9 timing:

| Library | Language | Encode 32 | Decode 32 | Encode 16 | Decode 16 |
|---|---|---:|---:|---:|---:|
| **zig-hilbert** | Zig 0.17 | **2.46** | **2.98** | **0.97** | **1.32** |
| [fast_hilbert 2.1.0](https://github.com/becheran/fast-hilbert) | Rust | 8.77 | 9.86 | 4.55 | 5.05 |
| [AdamSabol89/fast_hilbert](https://github.com/AdamSabol89/fast_hilbert) | Zig | 7.41 | broken | 4.20 | 9.92 |
| [HilbertCurveCompact](https://github.com/adolgert/HilbertCurveCompact) | Zig 0.14 | 95.5 | 84.9 | 41.2 | 36.8 |

All values are ns/point. All four libraries produce identical indices (equal
checksums), so they compute the same curve.

- **AdamSabol89/fast_hilbert.** At order 32 its `fromHilbert` returns
  coordinates above 2^32 for every one of 1,000,000 points tested, while its
  encoder is correct.
- **HilbertCurveCompact.** It targets Zig 0.14. To build it on 0.17, `run.sh`
  applies `hcc-zig-0.17.patch`, which makes four mechanical syntax changes
  and no algorithm changes. Its batch `encode_points` API runs at the same
  speed (94.7 ns at order 32). It does much more than this library: unequal
  axis extents, other Gray-code families, and arbitrarily wide indices. That
  generality is what the extra time pays for.

## Apple Silicon

- **CPU cores.** Batches and marker keys split work over all performance and
  efficiency cores with `std.Thread`. Work is chunked so small inputs stay
  on one thread.
- **NEON.** Marker projection is vectorized with `@Vector`: 8 output axes
  are 2 NEON registers, with 4 independent accumulators. A lane-parallel 2D
  encoder (`curve2d.encodeLanes`) is included and benchmarked. At 8.9
  ns/point it loses to the table, so the table is the default.
- **AMX / Accelerate are not used for marker keys.** BLAS does not specify
  its summation order, so the same note could get different keys on
  different machines or library versions. Keys use a fixed summation order
  and their own `exp` built from IEEE add, multiply, and scaling, so a
  marker computed on a Mac matches one computed on Linux x86. A golden
  marker test enforces this in every optimize mode, on arm64 and x86_64.
- **GPU (Metal).** Not in this version. At 0.2-0.4 ns/point on the CPU,
  copying data to the GPU and back costs more than the encode itself, for
  batches that fit in memory.
- **Neural Engine.** It runs neural networks, so it is where you would
  *produce* embeddings (Core ML). It cannot run this integer and bit
  arithmetic.

## Safety

- The checked APIs validate order, coordinates, and indices and return
  errors. The comptime APIs mask their inputs, so out-of-range bits can
  never index outside a table.
- `Marker.parse` accepts only canonical text: lowercase hex, exact widths,
  no leading zeros, and keys inside the space. One key therefore has exactly
  one spelling.
- Marker keys reject NaN, infinity, and zero vectors, and limit inputs to
  65536 dimensions.
- The CLI limits stdin to 256 MiB and reports errors on stderr with exit
  code 1.
- Tests run in Debug and ReleaseSafe, so every integer overflow and
  out-of-bounds access in the suite is checked at runtime.

## Development

```sh
zig build test          # tests
zig build bench         # full benchmark (always ReleaseFast)
zig build perf-check    # quick benchmark that fails on regressions
bench/compare/run.sh    # cross-library comparison (needs cargo, git, curl)
```

## Credits

- The 2D reference implementation (`src/reference.zig`) is the iterative
  algorithm from [Wikipedia: Hilbert curve](https://en.wikipedia.org/wiki/Hilbert_curve).
- The n-D curve uses the transpose method from J. Skilling, "Programming the
  Hilbert curve", *AIP Conference Proceedings* 707, 381 (2004),
  <https://doi.org/10.1063/1.1751381>.

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
