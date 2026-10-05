//! Knowledge-marker keys: a float embedding becomes a short, sortable,
//! versioned Hilbert key that can live in a database column or in markdown
//! frontmatter.
//!
//! Pipeline for an embedding `e` with `n` components:
//! 1. Sign projection: output axis `j` is `sum_i s(i, j) * e[i]`, where
//!    `s(i, j)` is -1 if bit `j` of the `i`-th SplitMix64 output for `seed`
//!    is set, else +1. For a unit vector each axis is roughly N(0, 1).
//! 2. Normalize by `|e|`, so the key depends on direction only (cosine).
//! 3. Quantize each axis through the logistic approximation of the normal
//!    CDF, `1 / (1 + exp(-1.702 z))`, into `2^bits` roughly equally likely
//!    cells.
//! 4. Map the `dims` cells to an index with the n-D Hilbert curve.
//!
//! Keys are bit-identical across platforms: the projection uses a fixed
//! summation order and `exp` is computed from IEEE basic operations.
//!
//! Nearby embeddings tend to share key prefixes, so a range scan over a key
//! prefix is a coarse candidate filter. Rerank candidates with the original
//! vectors; Hilbert order is not a nearest-neighbor index.

const std = @import("std");
const curvend = @import("curvend.zig");
const parallel = @import("parallel.zig");

pub const default_seed: u64 = 0x9e3779b97f4a7c15;
pub const default_dims: u8 = 8;
pub const default_bits: u8 = 8;
/// Caps the coefficient table at 8 MiB (65536 inputs x 32 lanes x 4 bytes).
pub const max_input_dims: u32 = 1 << 16;

/// A key costs about a microsecond, so far fewer rows than curve points
/// justify another thread.
pub const min_rows_per_thread = 256;

pub const Error = error{
    DimensionMismatch,
    ZeroVector,
    NonFiniteValue,
    DimensionsOutOfRange,
    OrderOutOfRange,
    OutputLengthMismatch,
};

pub const ParseError = error{InvalidMarker};

/// The i-th output (0-based) of SplitMix64 seeded with `seed`.
pub fn splitmix64(seed: u64, i: u64) u64 {
    var z = seed +% (i +% 1) *% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

pub const Options = struct {
    input_dims: u32,
    dims: u8 = default_dims,
    bits: u8 = default_bits,
    seed: u64 = default_seed,
};

/// A key together with the parameters that produced it.
pub const Marker = struct {
    dims: u8,
    bits: u8,
    seed: u64,
    key: u128,

    pub const prefix = "hk1:";
    /// Longest possible text form: `hk1:32:32:<16 hex>:<32 hex>`.
    pub const max_len = prefix.len + 2 + 1 + 2 + 1 + 16 + 1 + 32;

    pub fn keyBits(self: Marker) u16 {
        return @as(u16, self.dims) * self.bits;
    }

    fn hexWidth(total_bits: u16) usize {
        return (total_bits + 3) / 4;
    }

    /// `hk1:<dims>:<bits>:<seed>:<key>`, with the seed as 16 lowercase hex
    /// digits and the key zero-padded so text order equals numeric order
    /// within one space.
    pub fn format(self: Marker, buf: *[max_len]u8) []const u8 {
        var len: usize = 0;
        @memcpy(buf[0..prefix.len], prefix);
        len += prefix.len;
        len += writeDecimal(buf[len..], self.dims);
        buf[len] = ':';
        len += 1;
        len += writeDecimal(buf[len..], self.bits);
        buf[len] = ':';
        len += 1;
        writeHex(buf[len..][0..16], self.seed);
        len += 16;
        buf[len] = ':';
        len += 1;
        const width = hexWidth(self.keyBits());
        writeHex(buf[len..][0..width], self.key);
        return buf[0 .. len + width];
    }

    /// Strict inverse of `format`. Rejects uppercase hex, leading zeros,
    /// wrong widths, out-of-range parameters, and keys outside the space.
    pub fn parse(text: []const u8) ParseError!Marker {
        if (text.len > max_len or !std.mem.startsWith(u8, text, prefix)) return error.InvalidMarker;
        var it = std.mem.splitScalar(u8, text[prefix.len..], ':');
        const dims = try parseDecimal(it.next() orelse return error.InvalidMarker);
        const bits = try parseDecimal(it.next() orelse return error.InvalidMarker);
        const seed_text = it.next() orelse return error.InvalidMarker;
        const key_text = it.next() orelse return error.InvalidMarker;
        if (it.next() != null) return error.InvalidMarker;
        if (dims < 1 or dims > curvend.max_dims or bits < 1 or bits > curvend.max_bits) return error.InvalidMarker;
        const total = @as(u16, dims) * bits;
        if (total > curvend.max_index_bits) return error.InvalidMarker;
        if (seed_text.len != 16 or key_text.len != hexWidth(total)) return error.InvalidMarker;
        const seed: u64 = @intCast(try parseHex(seed_text));
        const key = try parseHex(key_text);
        if (total < 128 and key >> @intCast(total) != 0) return error.InvalidMarker;
        return .{ .dims = dims, .bits = bits, .seed = seed, .key = key };
    }

    /// Inclusive key bounds of the Hilbert cell that keeps `level` bits per
    /// axis (0 is the whole space, `bits` is this key alone). Use them for
    /// `WHERE key BETWEEN lo AND hi` scans.
    pub fn range(self: Marker, level: u8) struct { lo: Marker, hi: Marker } {
        const lvl = @min(level, self.bits);
        const drop: u16 = self.keyBits() - @as(u16, lvl) * self.dims;
        const low_mask: u128 = if (drop >= 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(drop)) - 1;
        var lo = self;
        var hi = self;
        lo.key = self.key & ~low_mask;
        hi.key = self.key | low_mask;
        return .{ .lo = lo, .hi = hi };
    }

    /// Number of leading key bits two markers share, or null when they come
    /// from different spaces and are not comparable.
    pub fn sharedPrefixBits(a: Marker, b: Marker) ?u16 {
        if (a.dims != b.dims or a.bits != b.bits or a.seed != b.seed) return null;
        const total = a.keyBits();
        const diff = a.key ^ b.key;
        if (diff == 0) return total;
        return total - (128 - @as(u16, @clz(diff)));
    }
};

fn writeDecimal(buf: []u8, v: u8) usize {
    if (v >= 10) {
        buf[0] = '0' + v / 10;
        buf[1] = '0' + v % 10;
        return 2;
    }
    buf[0] = '0' + v;
    return 1;
}

fn writeHex(buf: []u8, value: anytype) void {
    const digits = "0123456789abcdef";
    var v: u128 = value;
    var i = buf.len;
    while (i > 0) {
        i -= 1;
        buf[i] = digits[@intCast(v & 15)];
        v >>= 4;
    }
}

fn parseDecimal(text: []const u8) ParseError!u8 {
    if (text.len == 0 or text.len > 2) return error.InvalidMarker;
    if (text.len == 2 and text[0] == '0') return error.InvalidMarker;
    var v: u8 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.InvalidMarker;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn parseHex(text: []const u8) ParseError!u128 {
    if (text.len == 0 or text.len > 32) return error.InvalidMarker;
    var v: u128 = 0;
    for (text) |c| {
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => return error.InvalidMarker,
        };
        v = (v << 4) | d;
    }
    return v;
}

/// Projection and quantization parameters shared by every key in one space.
pub const Space = struct {
    dims: u8,
    bits: u8,
    seed: u64,
    input_dims: usize,
    /// Vector width used for the projection: the next power of two >= dims.
    lanes: usize,
    /// `coef[i * lanes + j]` is the sign of input `i` in output axis `j`,
    /// and 0 for padding lanes `j >= dims`.
    coef: []f32,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, options: Options) (Error || std.mem.Allocator.Error)!Space {
        if (options.input_dims < 1 or options.input_dims > max_input_dims) return error.DimensionMismatch;
        if (options.dims < 1 or options.dims > curvend.max_dims) return error.DimensionsOutOfRange;
        if (options.bits < 1 or options.bits > curvend.max_bits) return error.OrderOutOfRange;
        if (@as(u16, options.dims) * options.bits > curvend.max_index_bits) return error.OrderOutOfRange;
        const lanes = std.math.ceilPowerOfTwoAssert(usize, @max(options.dims, 2));
        const coef = try gpa.alloc(f32, options.input_dims * lanes);
        for (0..options.input_dims) |i| {
            const signs: u32 = @truncate(splitmix64(options.seed, i));
            for (0..lanes) |j| {
                coef[i * lanes + j] = if (j >= options.dims) 0 else if ((signs >> @intCast(j)) & 1 == 1) -1 else 1;
            }
        }
        return .{
            .dims = options.dims,
            .bits = options.bits,
            .seed = options.seed,
            .input_dims = options.input_dims,
            .lanes = lanes,
            .coef = coef,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Space) void {
        self.gpa.free(self.coef);
        self.* = undefined;
    }

    /// Quantized cell coordinates of `embedding`. Writes `dims` values.
    pub fn cell(self: *const Space, embedding: []const f32, out: []u32) Error!void {
        if (embedding.len != self.input_dims) return error.DimensionMismatch;
        if (out.len != self.dims) return error.OutputLengthMismatch;
        switch (self.lanes) {
            inline 2, 4, 8, 16, 32 => |l| try quantize(l, self.bits, self.coef, embedding, out),
            else => unreachable,
        }
    }

    pub fn key(self: *const Space, embedding: []const f32) Error!u128 {
        var buf: [curvend.max_dims]u32 = undefined;
        const c = buf[0..self.dims];
        try self.cell(embedding, c);
        return curvend.encodeChecked(self.dims, self.bits, c) catch unreachable;
    }

    pub fn marker(self: *const Space, embedding: []const f32) Error!Marker {
        return .{ .dims = self.dims, .bits = self.bits, .seed = self.seed, .key = try self.key(embedding) };
    }

    /// Keys for `embeddings`, stored row by row, across `threads` threads
    /// (0 = one per core). On failure returns the error of the first
    /// failing row and leaves `out` partly written.
    pub fn keys(self: *const Space, embeddings: []const f32, out: []u128, threads: usize) Error!void {
        const n = self.input_dims;
        if (embeddings.len != out.len * n) return error.DimensionMismatch;
        const Ctx = struct {
            space: *const Space,
            rows: []const f32,
            out: []u128,
            failed_row: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),
            failure: Error = undefined,
            mutex: std.atomic.Mutex = .unlocked,

            fn run(ctx: *@This(), start: usize, end: usize) void {
                const width = ctx.space.input_dims;
                for (start..end) |r| {
                    ctx.out[r] = ctx.space.key(ctx.rows[r * width ..][0..width]) catch |err| {
                        ctx.record(r, err);
                        return;
                    };
                }
            }

            fn record(ctx: *@This(), row: usize, err: Error) void {
                while (!ctx.mutex.tryLock()) std.atomic.spinLoopHint();
                defer ctx.mutex.unlock();
                if (row < ctx.failed_row.load(.monotonic)) {
                    ctx.failed_row.store(row, .monotonic);
                    ctx.failure = err;
                }
            }
        };
        var ctx: Ctx = .{ .space = self, .rows = embeddings, .out = out };
        parallel.forEachRange(out.len, threads, min_rows_per_thread, &ctx, Ctx.run);
        if (ctx.failed_row.load(.monotonic) != std.math.maxInt(usize)) return ctx.failure;
    }
};

/// Projects with four interleaved accumulators (input `i` goes to
/// accumulator `i % 4`, combined as `(a0 + a1) + (a2 + a3)`). Every step is
/// an IEEE add of an exactly signed input, so the result, and therefore the
/// key, is bit-identical on every platform.
fn quantize(comptime lanes: usize, bits: u8, coef: []const f32, e: []const f32, out: []u32) Error!void {
    const V = @Vector(lanes, f32);
    var acc: [4]V = @splat(@splat(0));
    var norm2: [4]f32 = @splat(0);
    var i: usize = 0;
    while (i + 4 <= e.len) : (i += 4) {
        inline for (0..4) |u| {
            const v = e[i + u];
            const c: V = coef[(i + u) * lanes ..][0..lanes].*;
            acc[u] += @as(V, @splat(v)) * c;
            norm2[u] += v * v;
        }
    }
    while (i < e.len) : (i += 1) {
        const v = e[i];
        const c: V = coef[i * lanes ..][0..lanes].*;
        acc[i % 4] += @as(V, @splat(v)) * c;
        norm2[i % 4] += v * v;
    }
    const sum: [lanes]f32 = (acc[0] + acc[1]) + (acc[2] + acc[3]);
    const n2 = (norm2[0] + norm2[1]) + (norm2[2] + norm2[3]);
    if (!std.math.isFinite(n2) or !std.math.isFinite(@reduce(.Add, @as(V, sum) * @as(V, sum)))) return error.NonFiniteValue;
    if (n2 == 0) return error.ZeroVector;
    const norm: f64 = @sqrt(@as(f64, n2));
    const cells: f64 = @floatFromInt(@as(u64, 1) << @intCast(bits));
    const top: u32 = @intCast((@as(u64, 1) << @intCast(bits)) - 1);
    for (out, 0..) |*o, j| {
        const z = @as(f64, sum[j]) / norm;
        const s = cells / (1 + exp(-1.702 * z));
        o.* = if (s >= cells) top else @min(@as(u32, @intFromFloat(s)), top);
    }
}

/// `e^x` from IEEE add, multiply, round, and exponent scaling only, so it
/// gives the same bits on every target (libm `exp` does not). Accurate to
/// about 1e-13 relative, which only matters for monotonicity here.
fn exp(x: f64) f64 {
    const t = std.math.clamp(x, -700, 700);
    const n = @round(t * 1.4426950408889634);
    const r = (t - n * 0.693145751953125) - n * 1.4286068203094172e-6;
    var p: f64 = 1.0 / 479001600.0;
    inline for (.{ 39916800.0, 3628800.0, 362880.0, 40320.0, 5040.0, 720.0, 120.0, 24.0, 6.0, 2.0, 1.0, 1.0 }) |d| {
        p = p * r + 1.0 / d;
    }
    return std.math.ldexp(p, @intFromFloat(n));
}

test "deterministic exp tracks std.math.exp" {
    for ([_]f64{ -700, -60, -3.4, -1, -0.5, 0, 1e-9, 0.25, 1, 2.5, 13.3, 60 }) |x| {
        const want = std.math.exp(x);
        try std.testing.expectApproxEqRel(want, exp(x), 1e-12);
    }
}

test "marker text round-trips and rejects malformed input" {
    const m: Marker = .{ .dims = 8, .bits = 8, .seed = default_seed, .key = 0x0123_4567_89ab_cdef };
    var buf: [Marker.max_len]u8 = undefined;
    const text = m.format(&buf);
    try std.testing.expectEqualStrings("hk1:8:8:9e3779b97f4a7c15:0123456789abcdef", text);
    try std.testing.expectEqual(m, try Marker.parse(text));
    const wide: Marker = .{ .dims = 32, .bits = 4, .seed = 1, .key = ~@as(u128, 0) };
    try std.testing.expectEqual(wide, try Marker.parse(wide.format(&buf)));
    const bad = [_][]const u8{
        "",
        "hk1:",
        "hk2:8:8:9e3779b97f4a7c15:0123456789abcdef",
        "hk1:08:8:9e3779b97f4a7c15:0123456789abcdef",
        "hk1:8:8:9E3779B97F4A7C15:0123456789abcdef",
        "hk1:8:8:9e3779b97f4a7c15:123456789abcdef",
        "hk1:8:8:9e3779b97f4a7c15:0123456789abcdef:",
        "hk1:0:8:9e3779b97f4a7c15:00",
        "hk1:33:1:9e3779b97f4a7c15:000000000",
        "hk1:16:16:9e3779b97f4a7c15:35b51b78bface751000000000000000000",
        "hk1:5:5:9e3779b97f4a7c15:fffffff",
        "hk1:8:8:9e3779b97f4a7c15:0123456789abcdeg",
        "hk1:8:8:9e3779b97f4a7c15:01234567-9abcdef",
    };
    for (bad) |b| try std.testing.expectError(error.InvalidMarker, Marker.parse(b));
}

test "range bounds contain the key and cover the right cell" {
    const m: Marker = .{ .dims = 4, .bits = 8, .seed = 7, .key = 0xdead_beef };
    const all = m.range(0);
    try std.testing.expectEqual(@as(u128, 0), all.lo.key);
    try std.testing.expectEqual(@as(u128, 0xffff_ffff), all.hi.key);
    const exact = m.range(8);
    try std.testing.expectEqual(m.key, exact.lo.key);
    try std.testing.expectEqual(m.key, exact.hi.key);
    const mid = m.range(4);
    try std.testing.expectEqual(@as(u128, 0xdead_0000), mid.lo.key);
    try std.testing.expectEqual(@as(u128, 0xdead_ffff), mid.hi.key);
    try std.testing.expectEqual(@as(?u16, 32), m.sharedPrefixBits(m));
    try std.testing.expectEqual(@as(?u16, null), m.sharedPrefixBits(.{ .dims = 4, .bits = 8, .seed = 8, .key = 0 }));
}

test "keys are deterministic, direction-only, and validated" {
    var space = try Space.init(std.testing.allocator, .{ .input_dims = 64 });
    defer space.deinit();
    var e: [64]f32 = undefined;
    for (&e, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.37);
    const k = try space.key(&e);
    try std.testing.expectEqual(k, try space.key(&e));
    var scaled = e;
    for (&scaled) |*v| v.* *= 3.5;
    try std.testing.expectEqual(k, try space.key(&scaled));
    var other = try Space.init(std.testing.allocator, .{ .input_dims = 64, .seed = 1 });
    defer other.deinit();
    try std.testing.expect(k != try other.key(&e));
    const zero: [64]f32 = @splat(0);
    try std.testing.expectError(error.ZeroVector, space.key(&zero));
    var nan = e;
    nan[10] = std.math.nan(f32);
    try std.testing.expectError(error.NonFiniteValue, space.key(&nan));
    var inf = e;
    inf[3] = std.math.inf(f32);
    try std.testing.expectError(error.NonFiniteValue, space.key(&inf));
    try std.testing.expectError(error.DimensionMismatch, space.key(e[0..63]));
    try std.testing.expectError(error.OrderOutOfRange, Space.init(std.testing.allocator, .{ .input_dims = 4, .dims = 16, .bits = 9 }));
    try std.testing.expectError(error.DimensionMismatch, Space.init(std.testing.allocator, .{ .input_dims = 0 }));
}

test "golden marker is identical on every platform" {
    var space = try Space.init(std.testing.allocator, .{ .input_dims = 384 });
    defer space.deinit();
    var e: [384]f32 = undefined;
    for (&e, 0..) |*v, i| v.* = @as(f32, @floatFromInt(@as(i32, @intCast(splitmix64(7, i) % 2001)) - 1000)) / 256;
    var buf: [Marker.max_len]u8 = undefined;
    try std.testing.expectEqualStrings("hk1:8:8:9e3779b97f4a7c15:35b51b78bface751", (try space.marker(&e)).format(&buf));
}

test "similar embeddings share longer key prefixes than unrelated ones" {
    const n = 384;
    var space = try Space.init(std.testing.allocator, .{ .input_dims = n });
    defer space.deinit();
    var prng = std.Random.DefaultPrng.init(2026);
    const r = prng.random();
    var near_total: u64 = 0;
    var far_total: u64 = 0;
    const trials = 400;
    for (0..trials) |_| {
        var a: [n]f32 = undefined;
        var b: [n]f32 = undefined;
        var c: [n]f32 = undefined;
        for (&a, &b, &c) |*x, *y, *z| {
            x.* = r.floatNorm(f32);
            y.* = x.* + 0.1 * r.floatNorm(f32);
            z.* = r.floatNorm(f32);
        }
        const ma = try space.marker(&a);
        near_total += ma.sharedPrefixBits(try space.marker(&b)).?;
        far_total += ma.sharedPrefixBits(try space.marker(&c)).?;
    }
    try std.testing.expect(near_total > 3 * far_total);
}

test "batch keys match single keys and report the first bad row" {
    const n = 32;
    const rows = 8 * min_rows_per_thread + 3;
    var space = try Space.init(std.testing.allocator, .{ .input_dims = n, .dims = 16, .bits = 8 });
    defer space.deinit();
    const data = try std.testing.allocator.alloc(f32, rows * n);
    defer std.testing.allocator.free(data);
    var prng = std.Random.DefaultPrng.init(9);
    for (data) |*v| v.* = prng.random().floatNorm(f32);
    const out = try std.testing.allocator.alloc(u128, rows);
    defer std.testing.allocator.free(out);
    try space.keys(data, out, 4);
    for (0..rows) |i| try std.testing.expectEqual(try space.key(data[i * n ..][0..n]), out[i]);
    @memset(data[5 * n ..][0..n], 0);
    data[9 * n] = std.math.nan(f32);
    try std.testing.expectError(error.ZeroVector, space.keys(data, out, 4));
    try std.testing.expectError(error.DimensionMismatch, space.keys(data[1..], out, 4));
}
