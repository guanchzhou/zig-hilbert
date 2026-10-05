//! n-dimensional Hilbert curve using Skilling's transpose construction:
//! J. Skilling, "Programming the Hilbert curve", AIP Conf. Proc. 707, 381
//! (2004), https://doi.org/10.1063/1.1751381
//!
//! The index is the transpose bit order: for each bit level from the most
//! significant down, one bit from axis 0, then axis 1, and so on. The inner
//! branches of the published algorithm are replaced by masks so encoding
//! takes the same path for every input.

const std = @import("std");

pub const max_dims = 32;
pub const max_bits = 32;
pub const max_index_bits = 128;

pub const Error = error{ OrderOutOfRange, DimensionsOutOfRange, CoordinateOutOfRange, IndexOutOfRange };

/// Index type for a comptime space.
pub fn Index(comptime dims: u8, comptime bits: u8) type {
    return @Int(.unsigned, @as(u16, dims) * bits);
}

fn validSpace(dims: u8, bits: u8) Error!void {
    if (dims < 1 or dims > max_dims) return error.DimensionsOutOfRange;
    if (bits < 1 or bits > max_bits) return error.OrderOutOfRange;
    if (@as(u16, dims) * bits > max_index_bits) return error.OrderOutOfRange;
}

inline fn bitMask(word: u32, level: u5) u32 {
    return 0 -% ((word >> level) & 1);
}

/// `x` points to an array, so the per-axis loops unroll.
inline fn axesToTranspose(x: anytype, bits: u8) void {
    const n = x.len;
    var level: u5 = @intCast(bits - 1);
    while (level > 0) : (level -= 1) {
        const p = (@as(u32, 1) << level) - 1;
        inline for (0..n) |i| {
            const invert = bitMask(x[i], level);
            x[0] ^= p & invert;
            const t = (x[0] ^ x[i]) & p & ~invert;
            x[0] ^= t;
            x[i] ^= t;
        }
    }
    inline for (1..n) |i| x[i] ^= x[i - 1];
    // Bit k of t is the parity of the bits of x[n - 1] above k.
    var t = x[n - 1] >> 1;
    inline for (.{ 1, 2, 4, 8, 16 }) |s| t ^= t >> s;
    inline for (0..n) |i| x[i] ^= t;
}

inline fn transposeToAxes(x: anytype, bits: u8) void {
    const n = x.len;
    const t = x[n - 1] >> 1;
    inline for (0..n - 1) |r| x[n - 1 - r] ^= x[n - 2 - r];
    x[0] ^= t;
    var level: u5 = 1;
    while (level < bits) : (level += 1) {
        const p = (@as(u32, 1) << level) - 1;
        inline for (0..n) |r| {
            const j = n - 1 - r;
            const invert = bitMask(x[j], level);
            x[0] ^= p & invert;
            const s = (x[0] ^ x[j]) & p & ~invert;
            x[0] ^= s;
            x[j] ^= s;
        }
        if (level == 31) break;
    }
}

/// Masks for spreading a 32-bit value so that bit `l` lands at `l * dims`.
/// Stage `i` works on blocks of `s = 32 >> i` bits; after it, block `k`
/// (bits `k*s ..`) sits at `k * s * dims`. Moving from blocks of `2s` to
/// blocks of `s` shifts every upper half by the same `s * (dims - 1)`.
fn spreadMasks(comptime dims: u8, comptime W: type) [6]W {
    @setEvalBranchQuota(100_000);
    const width = @bitSizeOf(W);
    const levels = @min(32, width / dims);
    var masks: [6]W = @splat(0);
    for (0..6) |i| {
        const s = 32 >> i;
        var k = 0;
        while (k * s < levels) : (k += 1) {
            const at = k * s * dims;
            if (at < width) masks[i] |= @as(W, @truncate((@as(u256, 1) << s) - 1)) << at;
        }
    }
    return masks;
}

inline fn spread(comptime dims: u8, comptime W: type, v: u32) W {
    if (dims == 1) return v;
    const masks = comptime spreadMasks(dims, W);
    var w: W = v;
    inline for (1..6) |i| {
        const shift = (32 >> i) * (@as(u32, dims) - 1);
        if (shift < @bitSizeOf(W)) w = (w | (w << shift)) & masks[i];
    }
    return w;
}

inline fn compress(comptime dims: u8, comptime W: type, w0: W) u32 {
    if (dims == 1) return @truncate(w0);
    const masks = comptime spreadMasks(dims, W);
    var w = w0 & masks[5];
    inline for (0..5) |r| {
        const i = 4 - r;
        const shift = (32 >> (i + 1)) * (@as(u32, dims) - 1);
        if (shift < @bitSizeOf(W)) w = (w | (w >> shift)) & masks[i];
    }
    return @truncate(w);
}

/// Transpose-order index of `x`: bit `l` of axis `j` lands at
/// `l * dims + (dims - 1 - j)`. Shift-and-mask spreading takes about
/// `5 * dims` operations instead of one step per index bit.
inline fn interleaveFast(comptime dims: u8, comptime W: type, x: *const [dims]u32) W {
    var h: W = 0;
    inline for (0..dims) |j| h |= spread(dims, W, x[j]) << (dims - 1 - j);
    return h;
}

inline fn deinterleaveFast(comptime dims: u8, comptime W: type, h: W, x: *[dims]u32) void {
    inline for (0..dims) |j| x[j] = compress(dims, W, h >> (dims - 1 - j));
}

/// Hilbert index of `point` in a `dims`-dimensional cube with `2^bits` cells
/// per side. Precondition: every coordinate is `< 2^bits`.
pub fn encode(comptime dims: u8, comptime bits: u8, point: [dims]u32) Index(dims, bits) {
    comptime validSpace(dims, bits) catch @compileError("unsupported space");
    var x = point;
    if (bits < 32) {
        for (&x) |*c| c.* &= (@as(u32, 1) << @intCast(bits)) - 1;
    }
    axesToTranspose(&x, bits);
    return @intCast(interleaveFast(dims, Word(dims, bits), &x));
}

/// Inverse of `encode`.
pub fn decode(comptime dims: u8, comptime bits: u8, index: Index(dims, bits)) [dims]u32 {
    comptime validSpace(dims, bits) catch @compileError("unsupported space");
    var x: [dims]u32 = undefined;
    deinterleaveFast(dims, Word(dims, bits), index, &x);
    transposeToAxes(&x, bits);
    return x;
}

/// Machine word wide enough for the index: one register when it fits.
fn Word(comptime dims: u8, comptime bits: u8) type {
    return if (@as(u16, dims) * bits <= 64) u64 else u128;
}

/// Runtime-space encode that validates its arguments. The index is
/// zero-extended to 128 bits.
pub fn encodeChecked(dims: u8, bits: u8, point: []const u32) Error!u128 {
    try validSpace(dims, bits);
    if (point.len != dims) return error.DimensionsOutOfRange;
    for (point) |c| {
        if (bits < 32 and c >> @intCast(bits) != 0) return error.CoordinateOutOfRange;
    }
    @setEvalBranchQuota(100_000);
    switch (dims) {
        inline 1...max_dims => |d| {
            var x: [d]u32 = point[0..d].*;
            axesToTranspose(&x, bits);
            return if (@as(u16, d) * bits <= 64) interleaveFast(d, u64, &x) else interleaveFast(d, u128, &x);
        },
        else => unreachable,
    }
}

/// Runtime-space decode that validates its arguments. Writes `dims`
/// coordinates to `out`.
pub fn decodeChecked(dims: u8, bits: u8, index: u128, out: []u32) Error!void {
    try validSpace(dims, bits);
    if (out.len != dims) return error.DimensionsOutOfRange;
    const total: u16 = @as(u16, dims) * bits;
    if (total < 128 and index >> @intCast(total) != 0) return error.IndexOutOfRange;
    @setEvalBranchQuota(100_000);
    switch (dims) {
        inline 1...max_dims => |d| {
            const x: *[d]u32 = out[0..d];
            if (total <= 64) deinterleaveFast(d, u64, @intCast(index), x) else deinterleaveFast(d, u128, index, x);
            transposeToAxes(x, bits);
        },
        else => unreachable,
    }
}

/// Decodes `out.len` consecutive indices `start, start + 1, ...`.
/// Precondition: the last index is inside the space.
///
/// Skilling's decode works from the lowest level up, and the step for each
/// level changes every lower level the same way: it permutes and
/// complements the axes, based only on that level's Gray-decoded bits.
/// Composing those maps from the top down instead means the next index
/// reuses every level above the highest digit that changed, which is one
/// level most of the time.
pub fn decodeRange(comptime dims: u8, comptime bits: u8, start: Index(dims, bits), out: [][dims]u32) void {
    comptime validSpace(dims, bits) catch @compileError("unsupported space");
    if (out.len == 0) return;
    std.debug.assert(out.len - 1 <= std.math.maxInt(Index(dims, bits)) - start);
    walk(dims, Word(dims, bits), bits, start, out);
}

/// Runtime-space `decodeRange` that validates its arguments. `out` holds
/// `dims` coordinates per point.
pub fn decodeRangeChecked(dims: u8, bits: u8, start: u128, out: []u32) Error!void {
    try validSpace(dims, bits);
    if (out.len % dims != 0) return error.DimensionsOutOfRange;
    const count = out.len / dims;
    if (count == 0) return;
    const total: u16 = @as(u16, dims) * bits;
    const max: u128 = if (total == 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(total)) - 1;
    if (start > max or count - 1 > max - start) return error.IndexOutOfRange;
    @setEvalBranchQuota(100_000);
    switch (dims) {
        inline 1...max_dims => |d| {
            const points: [][d]u32 = @as([*][d]u32, @ptrCast(out.ptr))[0..count];
            if (total <= 64) walk(d, u64, bits, @intCast(start), points) else walk(d, u128, bits, start, points);
        },
        else => unreachable,
    }
}

/// `v ↦ w` with `w[j] = v[p[j]] ^ f[j]` on one level's bits (bit `j` of a
/// column is axis `j`).
fn ColumnMap(comptime dims: u8) type {
    return struct {
        p: [dims]u8,
        f: u32,

        const identity: @This() = .{ .p = blk: {
            var p: [dims]u8 = undefined;
            for (&p, 0..) |*v, i| v.* = i;
            break :blk p;
        }, .f = 0 };

        inline fn apply(m: @This(), v: u32) u32 {
            var w: u32 = 0;
            inline for (0..dims) |j| w |= ((v >> @intCast(m.p[j])) & 1) << j;
            return w ^ m.f;
        }

        /// Skilling's step for one level with Gray-decoded column `g`: for
        /// axis `i` from the last down, complement axis 0 if bit `i` of `g`
        /// is set, else swap axes 0 and `i`.
        inline fn level(g: u32) @This() {
            var m = identity;
            inline for (0..dims) |r| {
                const i = dims - 1 - r;
                if ((g >> i) & 1 == 1) {
                    m.f ^= 1;
                } else if (i != 0) {
                    std.mem.swap(u8, &m.p[0], &m.p[i]);
                    const t = ((m.f >> i) ^ m.f) & 1;
                    m.f ^= t | (t << i);
                }
            }
            return m;
        }

        /// `s` after `a`: `(s ∘ a)(v) = s(a(v))`.
        inline fn then(a: @This(), s: @This()) @This() {
            var m: @This() = undefined;
            m.f = s.f;
            inline for (0..dims) |j| {
                m.p[j] = a.p[s.p[j]];
                m.f ^= ((a.f >> @intCast(s.p[j])) & 1) << j;
            }
            return m;
        }
    };
}

fn walk(comptime dims: u8, comptime W: type, bits: u8, start: W, out: [][dims]u32) void {
    const Map = ColumnMap(dims);
    const digit_mask: W = if (dims == @bitSizeOf(W)) std.math.maxInt(W) else (@as(W, 1) << dims) - 1;
    const Shift = std.math.Log2Int(W);
    // maps[L] composes the steps of every level above L.
    var maps: [max_bits]Map = undefined;
    var x: [dims]u32 = @splat(0);
    var h = start;
    maps[bits - 1] = Map.identity;
    refill(dims, W, bits, h, bits - 1, &maps, &x, digit_mask, Shift);
    out[0] = x;
    for (out[1..]) |*o| {
        const prev = h;
        h +%= 1;
        const top: u8 = @intCast((@bitSizeOf(W) - 1 - @clz(prev ^ h)) / dims);
        refill(dims, W, bits, h, @min(top, bits - 1), &maps, &x, digit_mask, Shift);
        o.* = x;
    }
}

/// Recomputes levels `top` down to 0 of `x` for index `h`, using
/// `maps[top]` and rewriting `maps` below it.
inline fn refill(comptime dims: u8, comptime W: type, bits: u8, h: W, top: u8, maps: []ColumnMap(dims), x: *[dims]u32, digit_mask: W, comptime Shift: type) void {
    const keep: u32 = if (top == 31) 0 else ~((@as(u32, 2) << @intCast(top)) - 1);
    inline for (x) |*c| c.* &= keep;
    var level: u8 = top + 1;
    while (level > 0) {
        level -= 1;
        const digit: u32 = @intCast((h >> @as(Shift, @intCast(@as(u16, level) * dims))) & digit_mask);
        const col = @bitReverse(digit) >> @intCast(32 - @as(u32, dims));
        const above: u32 = if (level + 1 == bits) 0 else @intCast((h >> @as(Shift, @intCast(@as(u16, level + 1) * dims))) & 1);
        const g = col ^ ((col << 1) & @as(u32, @truncate(digit_mask))) ^ above;
        const w = maps[level].apply(g);
        inline for (x, 0..) |*c, j| c.* |= ((w >> j) & 1) << @intCast(level);
        if (level > 0) maps[level - 1] = ColumnMap(dims).level(g).then(maps[level]);
    }
}

fn expectCurve(comptime dims: u8, comptime bits: u8) !void {
    const total: u32 = @as(u32, dims) * bits;
    const count: u64 = @as(u64, 1) << @intCast(total);
    var prev: [dims]u32 = decode(dims, bits, 0);
    for (prev) |c| try std.testing.expectEqual(@as(u32, 0), c);
    var seen = try std.testing.allocator.alloc(bool, @intCast(count));
    defer std.testing.allocator.free(seen);
    @memset(seen, false);
    var h: u64 = 0;
    while (h < count) : (h += 1) {
        const p = decode(dims, bits, @intCast(h));
        try std.testing.expectEqual(@as(Index(dims, bits), @intCast(h)), encode(dims, bits, p));
        var flat: u64 = 0;
        for (p) |c| flat = (flat << @intCast(bits)) | c;
        try std.testing.expect(!seen[@intCast(flat)]);
        seen[@intCast(flat)] = true;
        if (h > 0) {
            var steps: u32 = 0;
            for (p, prev) |a, b| steps += if (a > b) a - b else b - a;
            try std.testing.expectEqual(@as(u32, 1), steps);
        }
        prev = p;
    }
}

test "n-D curve is a continuous bijection starting at the origin" {
    inline for (.{ .{ 1, 4 }, .{ 2, 1 }, .{ 2, 5 }, .{ 3, 1 }, .{ 3, 4 }, .{ 4, 3 }, .{ 5, 2 }, .{ 6, 2 }, .{ 8, 1 }, .{ 12, 1 } }) |s| {
        try expectCurve(s[0], s[1]);
    }
}

test "n-D matches Skilling's branching algorithm, including 128-bit spaces" {
    const reference = @import("reference.zig");
    var prng = std.Random.DefaultPrng.init(5);
    const r = prng.random();
    inline for (.{ .{ 4, 32 }, .{ 8, 16 }, .{ 32, 4 }, .{ 3, 21 }, .{ 16, 8 }, .{ 1, 32 }, .{ 2, 32 }, .{ 5, 25 } }) |s| {
        const dims = s[0];
        const bits = s[1];
        for (0..2000) |_| {
            var p: [dims]u32 = undefined;
            for (&p) |*c| c.* = if (bits == 32) r.int(u32) else r.uintLessThan(u32, @as(u32, 1) << bits);
            const want = reference.encodeNd(bits, &p);
            try std.testing.expectEqual(want, encode(dims, bits, p));
            try std.testing.expectEqual(want, try encodeChecked(dims, bits, &p));
            var back: [dims]u32 = undefined;
            reference.decodeNd(bits, want, &back);
            try std.testing.expectEqualSlices(u32, &p, &back);
            try std.testing.expectEqualSlices(u32, &p, &decode(dims, bits, @intCast(want)));
        }
    }
    for (0..20_000) |_| {
        const dims = r.intRangeAtMost(u8, 1, max_dims);
        const bits = r.intRangeAtMost(u8, 1, @min(max_bits, max_index_bits / dims));
        var p: [max_dims]u32 = undefined;
        for (p[0..dims]) |*c| c.* = if (bits == 32) r.int(u32) else r.uintLessThan(u32, @as(u32, 1) << @intCast(bits));
        const want = reference.encodeNd(bits, p[0..dims]);
        try std.testing.expectEqual(want, try encodeChecked(dims, bits, p[0..dims]));
        var back: [max_dims]u32 = undefined;
        try decodeChecked(dims, bits, want, back[0..dims]);
        try std.testing.expectEqualSlices(u32, p[0..dims], back[0..dims]);
    }
}

fn expectRange(comptime dims: u8, comptime bits: u8, start: Index(dims, bits), count: usize) !void {
    var buf: [4096][dims]u32 = undefined;
    const out = buf[0..count];
    decodeRange(dims, bits, start, out);
    for (out, 0..) |p, i| try std.testing.expectEqualSlices(u32, &decode(dims, bits, start + @as(Index(dims, bits), @intCast(i))), &p);
}

test "decodeRange matches decode for every consecutive index" {
    inline for (.{ .{ 1, 4 }, .{ 2, 1 }, .{ 2, 5 }, .{ 3, 4 }, .{ 4, 3 }, .{ 5, 2 }, .{ 6, 2 }, .{ 12, 1 } }) |s| {
        const total = @as(usize, 1) << (s[0] * s[1]);
        try expectRange(s[0], s[1], 0, total);
    }
    var prng = std.Random.DefaultPrng.init(17);
    const r = prng.random();
    inline for (.{ .{ 3, 21 }, .{ 8, 8 }, .{ 4, 32 }, .{ 32, 4 }, .{ 16, 8 }, .{ 1, 32 }, .{ 2, 32 }, .{ 5, 25 }, .{ 2, 16 } }) |s| {
        const I = Index(s[0], s[1]);
        const max = std.math.maxInt(I);
        for (0..20) |_| try expectRange(s[0], s[1], r.int(I) % (max - 4096), 4096);
        try expectRange(s[0], s[1], max - 4095, 4096);
        try expectRange(s[0], s[1], 0, 4096);
        // Carries through many levels at once.
        try expectRange(s[0], s[1], (@as(I, 1) << (@bitSizeOf(I) - 1)) - 2048, 4096);
    }
}

test "decodeRangeChecked matches decodeRange and validates" {
    var flat: [3 * 500]u32 = undefined;
    try decodeRangeChecked(3, 21, 123456789, &flat);
    var want: [500][3]u32 = undefined;
    decodeRange(3, 21, 123456789, &want);
    try std.testing.expectEqualSlices(u32, @as(*const [1500]u32, @ptrCast(&want)), &flat);
    try std.testing.expectError(error.IndexOutOfRange, decodeRangeChecked(3, 21, (1 << 63) - 499, &flat));
    try decodeRangeChecked(3, 21, (1 << 63) - 500, &flat);
    try std.testing.expectError(error.DimensionsOutOfRange, decodeRangeChecked(3, 21, 0, flat[0..10]));
    try std.testing.expectError(error.OrderOutOfRange, decodeRangeChecked(5, 32, 0, flat[0..5]));
    var wide: [4 * 8]u32 = undefined;
    try decodeRangeChecked(4, 32, std.math.maxInt(u128) - 7, &wide);
    try std.testing.expectEqualSlices(u32, &decode(4, 32, std.math.maxInt(u128)), wide[28..32]);
}

test "checked n-D matches comptime n-D and rejects bad input" {
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    for (0..2000) |_| {
        var p: [8]u32 = undefined;
        for (&p) |*c| c.* = r.int(u16);
        const h = encode(8, 16, p);
        try std.testing.expectEqual(@as(u128, h), try encodeChecked(8, 16, &p));
        var back: [8]u32 = undefined;
        try decodeChecked(8, 16, h, &back);
        try std.testing.expectEqualSlices(u32, &p, &back);
        try std.testing.expectEqualSlices(u32, &p, &decode(8, 16, h));
    }
    const wide: [4]u32 = .{ 0xffff_ffff, 1, 0x8000_0000, 7 };
    const hw = encode(4, 32, wide);
    try std.testing.expectEqualSlices(u32, &wide, &decode(4, 32, hw));
    try std.testing.expectError(error.CoordinateOutOfRange, encodeChecked(2, 4, &.{ 16, 0 }));
    try std.testing.expectError(error.OrderOutOfRange, encodeChecked(5, 32, &.{ 0, 0, 0, 0, 0 }));
    try std.testing.expectError(error.DimensionsOutOfRange, encodeChecked(0, 4, &.{}));
    try std.testing.expectError(error.DimensionsOutOfRange, encodeChecked(3, 4, &.{ 1, 2 }));
    var out: [2]u32 = undefined;
    try std.testing.expectError(error.IndexOutOfRange, decodeChecked(2, 4, 256, &out));
}
