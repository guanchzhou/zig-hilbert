//! Knowledge-marker keys: a float embedding becomes a short, sortable,
//! versioned Hilbert key that can live in a database column or in markdown
//! frontmatter.
//!
//! Pipeline for an embedding `e` with `n` components:
//! 1. Sign projection: output axis `j` is `sum_i s(i, j) * e[i]`, where
//!    `s(i, j)` is -1 if bit `j` of the `i`-th SplitMix64 output for `seed`
//!    is set, else +1. For a unit vector each axis is roughly N(0, 1).
//! 2. Normalize by `|e|`, so the key depends on direction (cosine). Scaling
//!    `e` by a power of two gives exactly the same key while the scaled
//!    values stay normal floats, up to `floatMax(f32)`. Other scale factors
//!    round differently and can, rarely, move a point across a cell
//!    boundary.
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

/// Inclusive key interval, as used in `key BETWEEN lo AND hi`.
pub const KeyRange = struct { lo: u128, hi: u128 };

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
        try self.place(u32, embedding, out);
    }

    /// Like `cell`, but in continuous cell units: axis `j` lies in cell
    /// `floor(out[j])` (clamped to the last cell), and the fraction shows
    /// how close it is to the neighbouring cells.
    pub fn position(self: *const Space, embedding: []const f32, out: []f64) Error!void {
        try self.place(f64, embedding, out);
    }

    fn place(self: *const Space, comptime T: type, embedding: []const f32, out: []T) Error!void {
        if (embedding.len != self.input_dims) return error.DimensionMismatch;
        if (out.len != self.dims) return error.OutputLengthMismatch;
        switch (self.lanes) {
            inline 2, 4, 8, 16, 32 => |l| try quantize(l, T, self.bits, self.coef, embedding, out),
            else => unreachable,
        }
    }

    /// Key ranges to scan for neighbours of `embedding` at `level` bits per
    /// axis: the cell `Marker.range(level)` covers, plus the adjacent cells
    /// across the boundaries the point is closest to, as many as fit in
    /// `out` (whole sets of 2^k cells for the k nearest boundaries).
    /// Returns them sorted and merged, so the result can be shorter than
    /// `out`. Use them as `key BETWEEN lo AND hi OR ...`.
    pub fn probes(self: *const Space, embedding: []const f32, level: u8, out: []KeyRange) Error![]KeyRange {
        if (out.len == 0) return error.OutputLengthMismatch;
        var pos_buf: [curvend.max_dims]f64 = undefined;
        const pos = pos_buf[0..self.dims];
        try self.position(embedding, pos);
        const total: u16 = @as(u16, self.dims) * self.bits;
        const lvl = @min(level, self.bits);
        if (lvl == 0) {
            out[0] = .{ .lo = 0, .hi = if (total == 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(total)) - 1 };
            return out[0..1];
        }
        const shift: u5 = @intCast(self.bits - lvl);
        const side: u32 = @intCast((@as(u64, 1) << @intCast(lvl)) - 1);
        const unit: f64 = @floatFromInt(@as(u64, 1) << shift);
        var coarse: [curvend.max_dims]u32 = undefined;
        var near: [curvend.max_dims]struct { axis: u8, dist: f64, step: i2 } = undefined;
        var candidates: usize = 0;
        for (pos, 0..) |p, j| {
            const scaled = p / unit;
            const c: u32 = @min(@as(u32, @intFromFloat(@floor(scaled))), side);
            coarse[j] = c;
            const frac = scaled - @as(f64, @floatFromInt(c));
            const step: i2 = if (frac < 0.5) -1 else 1;
            if ((step == -1 and c == 0) or (step == 1 and c == side)) continue;
            near[candidates] = .{ .axis = @intCast(j), .dist = if (step == -1) frac else 1 - frac, .step = step };
            candidates += 1;
        }
        std.mem.sort(@TypeOf(near[0]), near[0..candidates], {}, struct {
            fn lessThan(_: void, a: @TypeOf(near[0]), b: @TypeOf(near[0])) bool {
                return a.dist < b.dist or (a.dist == b.dist and a.axis < b.axis);
            }
        }.lessThan);
        const k = @min(candidates, std.math.log2_int(usize, out.len));
        const drop: u7 = @intCast(total - @as(u16, lvl) * self.dims);
        const low: u128 = (@as(u128, 1) << drop) - 1;
        const count = @as(usize, 1) << @intCast(k);
        for (0..count) |mask| {
            var c = coarse;
            for (near[0..k], 0..) |n, b| {
                if ((mask >> @intCast(b)) & 1 == 1) {
                    c[n.axis] = if (n.step == -1) c[n.axis] - 1 else c[n.axis] + 1;
                }
            }
            for (c[0..self.dims]) |*v| v.* <<= shift;
            const key_ = curvend.encodeChecked(self.dims, self.bits, c[0..self.dims]) catch unreachable;
            out[mask] = .{ .lo = key_ & ~low, .hi = key_ | low };
        }
        const ranges = out[0..count];
        std.mem.sort(KeyRange, ranges, {}, struct {
            fn lessThan(_: void, a: KeyRange, b: KeyRange) bool {
                return a.lo < b.lo;
            }
        }.lessThan);
        var merged: usize = 0;
        for (ranges) |r| {
            if (merged > 0 and out[merged - 1].hi +% 1 == r.lo) {
                out[merged - 1].hi = r.hi;
            } else {
                out[merged] = r;
                merged += 1;
            }
        }
        return out[0..merged];
    }

    pub fn key(self: *const Space, embedding: []const f32) Error!u128 {
        var buf: [curvend.max_dims]u32 = undefined;
        const c = buf[0..self.dims];
        try self.cell(embedding, c);
        return curvend.encodeChecked(self.dims, self.bits, c) catch unreachable;
    }

    /// Keys of two rows, sharing the coefficient loads. Rows that need the
    /// rescaling path, or fail, go through `key` on their own.
    fn keyPair(self: *const Space, a: []const f32, b: []const f32) [2]Error!u128 {
        switch (self.lanes) {
            inline 2, 4, 8, 16, 32 => |l| {
                const p = project2(l, self.coef, a, b);
                var out: [2]Error!u128 = undefined;
                inline for (.{ a, b }, 0..) |row, r| {
                    if (p[r].n2 >= min_norm2 and p[r].n2 <= std.math.floatMax(f32)) {
                        var buf: [curvend.max_dims]u32 = undefined;
                        finish(l, u32, self.bits, p[r].sum, p[r].n2, buf[0..self.dims]);
                        out[r] = curvend.encodeChecked(self.dims, self.bits, buf[0..self.dims]) catch unreachable;
                    } else {
                        out[r] = self.key(row);
                    }
                }
                return out;
            },
            else => unreachable,
        }
    }

    pub fn marker(self: *const Space, embedding: []const f32) Error!Marker {
        return .{ .dims = self.dims, .bits = self.bits, .seed = self.seed, .key = try self.key(embedding) };
    }

    /// Keys for `embeddings`, stored row by row. `exec` is a thread count
    /// (0 = one per core) or a `std.Io` to submit the work to. On failure
    /// returns the error of the first failing row, stores that row's index
    /// in `failed_row` if given, and leaves `out` partly written.
    pub fn keys(self: *const Space, embeddings: []const f32, out: []u128, exec: anytype, failed_row: ?*usize) (Error || parallel.ExecError(@TypeOf(exec)))!void {
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
                var r = start;
                while (r + 2 <= end) : (r += 2) {
                    const pair = ctx.space.keyPair(ctx.rows[r * width ..][0..width], ctx.rows[(r + 1) * width ..][0..width]);
                    inline for (pair, 0..) |k, i| {
                        ctx.out[r + i] = k catch |err| return ctx.record(r + i, err);
                    }
                }
                if (r < end) {
                    ctx.out[r] = ctx.space.key(ctx.rows[r * width ..][0..width]) catch |err| return ctx.record(r, err);
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
        try parallel.run(exec, out.len, min_rows_per_thread, &ctx, Ctx.run);
        const row = ctx.failed_row.load(.monotonic);
        if (row != std.math.maxInt(usize)) {
            if (failed_row) |f| f.* = row;
            return ctx.failure;
        }
    }
};

/// Projects with four interleaved accumulators (input `i` goes to
/// accumulator `i % 4`, combined as `(a0 + a1) + (a2 + a3)`). Every step is
/// an IEEE add of an exactly signed input, so the result, and therefore the
/// key, is bit-identical on every platform.
fn quantize(comptime lanes: usize, comptime T: type, bits: u8, coef: []const f32, e: []const f32, out: []T) Error!void {
    var p = project(lanes, coef, e, false, .{ 1, 1 });
    if (!(p.n2 >= min_norm2 and p.n2 <= std.math.floatMax(f32))) {
        // Overflow, underflow, NaN, or infinity. Rescale by an exact power of
        // two so the result equals the unscaled one wherever that is finite.
        p = project(lanes, coef, e, true, try rescale(e));
    }
    finish(lanes, T, bits, p.sum, p.n2, out);
}

/// Two power-of-two factors whose product brings the largest magnitude of
/// `e` into [0.5, 1). Two factors because 2^149 (for subnormal input) does
/// not fit in one f32.
fn rescale(e: []const f32) Error![2]f32 {
    var max: f32 = 0;
    for (e) |v| {
        const a = @abs(v);
        if (!(a <= std.math.floatMax(f32))) return error.NonFiniteValue;
        max = @max(max, a);
    }
    if (max == 0) return error.ZeroVector;
    const shift = -std.math.frexp(max).exponent;
    const half = @divTrunc(shift, 2);
    return .{ std.math.ldexp(@as(f32, 1), half), std.math.ldexp(@as(f32, 1), shift - half) };
}

/// Squared norms below this lose precision to f32 underflow and take the
/// rescaling path.
const min_norm2: f32 = 0x1p-100;

fn Projection(comptime lanes: usize) type {
    return struct { sum: [lanes]f32, n2: f32 };
}

/// The coefficients are exactly -1, 0, or 1, so `v * c` is exact and a
/// fused multiply-add rounds exactly like the separate multiply and add.
/// The squared norm is not exact, so it keeps a separate multiply and add;
/// its vector lane `u` is accumulator `i % 4`.
fn project(comptime lanes: usize, coef: []const f32, e: []const f32, comptime scaled: bool, scale: [2]f32) Projection(lanes) {
    const V = @Vector(lanes, f32);
    const V4 = @Vector(4, f32);
    var acc: [4]V = @splat(@splat(0));
    var norm2v: V4 = @splat(0);
    var i: usize = 0;
    while (i + 4 <= e.len) : (i += 4) {
        var v4: V4 = e[i..][0..4].*;
        if (scaled) v4 = v4 * @as(V4, @splat(scale[0])) * @as(V4, @splat(scale[1]));
        norm2v += v4 * v4;
        inline for (0..4) |u| {
            const c: V = coef[(i + u) * lanes ..][0..lanes].*;
            acc[u] = @mulAdd(V, @splat(v4[u]), c, acc[u]);
        }
    }
    var norm2: [4]f32 = norm2v;
    while (i < e.len) : (i += 1) {
        const v = if (scaled) e[i] * scale[0] * scale[1] else e[i];
        const c: V = coef[i * lanes ..][0..lanes].*;
        acc[i % 4] = @mulAdd(V, @splat(v), c, acc[i % 4]);
        norm2[i % 4] += v * v;
    }
    return .{ .sum = (acc[0] + acc[1]) + (acc[2] + acc[3]), .n2 = (norm2[0] + norm2[1]) + (norm2[2] + norm2[3]) };
}

/// `project` for two rows at once: each coefficient vector is loaded once
/// for both. Each row goes through exactly the operations `project` does.
fn project2(comptime lanes: usize, coef: []const f32, e0: []const f32, e1: []const f32) [2]Projection(lanes) {
    const V = @Vector(lanes, f32);
    const V4 = @Vector(4, f32);
    var acc: [2][4]V = @splat(@splat(@splat(0)));
    var norm2v: [2]V4 = @splat(@splat(0));
    var i: usize = 0;
    while (i + 4 <= e0.len) : (i += 4) {
        const a: V4 = e0[i..][0..4].*;
        const b: V4 = e1[i..][0..4].*;
        norm2v[0] += a * a;
        norm2v[1] += b * b;
        inline for (0..4) |u| {
            const c: V = coef[(i + u) * lanes ..][0..lanes].*;
            acc[0][u] = @mulAdd(V, @splat(a[u]), c, acc[0][u]);
            acc[1][u] = @mulAdd(V, @splat(b[u]), c, acc[1][u]);
        }
    }
    var norm2: [2][4]f32 = .{ norm2v[0], norm2v[1] };
    while (i < e0.len) : (i += 1) {
        const c: V = coef[i * lanes ..][0..lanes].*;
        inline for (.{ e0, e1 }, 0..) |e, r| {
            acc[r][i % 4] = @mulAdd(V, @splat(e[i]), c, acc[r][i % 4]);
            norm2[r][i % 4] += e[i] * e[i];
        }
    }
    var out: [2]Projection(lanes) = undefined;
    inline for (0..2) |r| out[r] = .{
        .sum = (acc[r][0] + acc[r][1]) + (acc[r][2] + acc[r][3]),
        .n2 = (norm2[r][0] + norm2[r][1]) + (norm2[r][2] + norm2[r][3]),
    };
    return out;
}

fn finish(comptime lanes: usize, comptime T: type, bits: u8, sum: [lanes]f32, n2: f32, out: []T) void {
    const VF = @Vector(lanes, f64);
    const norm: f64 = @sqrt(@as(f64, n2));
    const cells: f64 = @floatFromInt(@as(u64, 1) << @intCast(bits));
    const top: u32 = @intCast((@as(u64, 1) << @intCast(bits)) - 1);
    const z = @as(VF, @floatCast(@as(@Vector(lanes, f32), sum))) / @as(VF, @splat(norm));
    const one: VF = @splat(1);
    const scaled: [lanes]f64 = @as(VF, @splat(cells)) / (one + exp(@as(VF, @splat(-1.702)) * z));
    for (out, scaled[0..out.len]) |*o, s| {
        o.* = switch (T) {
            f64 => s,
            u32 => if (s >= cells) top else @min(@as(u32, @intFromFloat(s)), top),
            else => @compileError("unsupported"),
        };
    }
}

/// `e^x` from IEEE add, multiply, round, and exponent scaling only, so it
/// gives the same bits on every target (libm `exp` does not). Accurate to
/// about 1e-13 relative, which only matters for monotonicity here. Works on
/// `f64` and `f64` vectors. After the clamp, `n` is within +-1010 and
/// `p * 2^n` is a normal number, so building `2^n` from its exponent bits
/// is exact.
fn exp(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    const I = if (@typeInfo(T) == .vector) @Vector(@typeInfo(T).vector.len, i64) else i64;
    const U = if (@typeInfo(T) == .vector) @Vector(@typeInfo(T).vector.len, u64) else u64;
    const k = struct {
        fn c(v: f64) T {
            return if (@typeInfo(T) == .vector) @splat(v) else v;
        }
    }.c;
    const t = @min(@max(x, k(-700)), k(700));
    const n = @round(t * k(1.4426950408889634));
    const r = (t - n * k(0.693145751953125)) - n * k(1.4286068203094172e-6);
    var p: T = k(1.0 / 479001600.0);
    inline for (.{ 39916800.0, 3628800.0, 362880.0, 40320.0, 5040.0, 720.0, 120.0, 24.0, 6.0, 2.0, 1.0, 1.0 }) |d| {
        p = p * r + k(1.0 / d);
    }
    const ni: I = @intFromFloat(n);
    const bias: I = if (@typeInfo(T) == .vector) @splat(1023) else 1023;
    const shift: if (@typeInfo(T) == .vector) @Vector(@typeInfo(T).vector.len, u6) else u6 = if (@typeInfo(T) == .vector) @splat(52) else 52;
    const two_n: T = @bitCast(@as(U, @bitCast(ni + bias)) << shift);
    return p * two_n;
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
    for ([_]i32{ -100, -60, -1, 1, 30, 60, 100, 126 }) |shift| {
        var scaled = e;
        for (&scaled) |*v| v.* = std.math.ldexp(v.*, shift);
        try std.testing.expectEqual(k, try space.key(&scaled));
    }
    var huge = e;
    huge[5] = std.math.floatMax(f32);
    _ = try space.key(&huge);
    var tiny: [64]f32 = @splat(0);
    tiny[9] = std.math.floatTrueMin(f32);
    _ = try space.key(&tiny);
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

fn covered(ranges: []const KeyRange, k: u128) bool {
    for (ranges) |r| if (r.lo <= k and k <= r.hi) return true;
    return false;
}

test "probes include the home cell and recover neighbours across boundaries" {
    const n = 96;
    var space = try Space.init(std.testing.allocator, .{ .input_dims = n });
    defer space.deinit();
    var prng = std.Random.DefaultPrng.init(21);
    const r = prng.random();
    var home_hits: usize = 0;
    var probe_hits: usize = 0;
    for (0..400) |_| {
        var a: [n]f32 = undefined;
        var b: [n]f32 = undefined;
        for (&a, &b) |*x, *y| {
            x.* = r.floatNorm(f32);
            y.* = x.* + 0.15 * r.floatNorm(f32);
        }
        const ma = try space.marker(&a);
        const kb = try space.key(&b);
        var buf: [16]KeyRange = undefined;
        const ranges = try space.probes(&a, 2, &buf);
        const home = ma.range(2);
        try std.testing.expect(covered(ranges, ma.key));
        try std.testing.expect(covered(ranges, home.lo.key) and covered(ranges, home.hi.key));
        for (ranges[1..], ranges[0 .. ranges.len - 1]) |cur, prev| try std.testing.expect(prev.hi +% 1 < cur.lo);
        if (home.lo.key <= kb and kb <= home.hi.key) home_hits += 1;
        if (covered(ranges, kb)) probe_hits += 1;
    }
    try std.testing.expect(probe_hits > home_hits + home_hits / 4);

    var one: [1]KeyRange = undefined;
    var e: [n]f32 = @splat(1);
    e[0] = 2;
    const m = try space.marker(&e);
    const single = try space.probes(&e, 3, &one);
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqual(m.range(3).lo.key, single[0].lo);
    try std.testing.expectEqual(m.range(3).hi.key, single[0].hi);
    const all = try space.probes(&e, 0, &one);
    try std.testing.expectEqual(KeyRange{ .lo = 0, .hi = std.math.maxInt(u64) }, all[0]);
    try std.testing.expectError(error.OutputLengthMismatch, space.probes(&e, 3, one[0..0]));
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
    try space.keys(data, out, 4, null);
    for (0..rows) |i| try std.testing.expectEqual(try space.key(data[i * n ..][0..n]), out[i]);
    const via_io = try std.testing.allocator.alloc(u128, rows);
    defer std.testing.allocator.free(via_io);
    try space.keys(data, via_io, std.testing.io, null);
    try std.testing.expectEqualSlices(u128, out, via_io);
    const late = rows - 2;
    data[late * n] = std.math.inf(f32);
    var failed: usize = undefined;
    try std.testing.expectError(error.NonFiniteValue, space.keys(data, out, 4, &failed));
    try std.testing.expectEqual(late, failed);
    @memset(data[5 * n ..][0..n], 0);
    data[9 * n] = std.math.nan(f32);
    try std.testing.expectError(error.ZeroVector, space.keys(data, out, 4, &failed));
    try std.testing.expectEqual(@as(usize, 5), failed);
    try std.testing.expectError(error.DimensionMismatch, space.keys(data[1..], out, 4, null));
}
