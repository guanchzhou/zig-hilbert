//! Bit-serial reference implementations. They are slow on purpose: every
//! other encoder in the package is tested against these.

const std = @import("std");

/// Hilbert index of `(x, y)` on a `2^bits` by `2^bits` grid, processing one
/// bit level per iteration (the classic `xy2d` formulation).
pub fn encode2(bits: u6, x: u32, y: u32) u64 {
    const n: u64 = @as(u64, 1) << bits;
    var px: u64 = x;
    var py: u64 = y;
    var d: u64 = 0;
    var s: u64 = n >> 1;
    while (s > 0) : (s >>= 1) {
        const rx: u64 = @intFromBool(px & s != 0);
        const ry: u64 = @intFromBool(py & s != 0);
        d += s * s * ((3 * rx) ^ ry);
        if (ry == 0) {
            if (rx == 1) {
                px = n - 1 - px;
                py = n - 1 - py;
            }
            const t = px;
            px = py;
            py = t;
        }
    }
    return d;
}

/// Inverse of `encode2`.
pub fn decode2(bits: u6, index: u64) [2]u32 {
    const n: u64 = @as(u64, 1) << bits;
    var px: u64 = 0;
    var py: u64 = 0;
    var t = index;
    var s: u64 = 1;
    while (s < n) : (s <<= 1) {
        const rx: u64 = 1 & (t >> 1);
        const ry: u64 = 1 & (t ^ rx);
        if (ry == 0) {
            if (rx == 1) {
                px = s - 1 - px;
                py = s - 1 - py;
            }
            const tmp = px;
            px = py;
            py = tmp;
        }
        px += s * rx;
        py += s * ry;
        t >>= 2;
    }
    return .{ @intCast(px), @intCast(py) };
}

/// n-D Hilbert index of `point` (`2^bits` cells per side, at most 128 index
/// bits), using Skilling's published `AxestoTranspose` with its branches,
/// then one index bit per step: for each level from the top, axis 0 first.
/// J. Skilling, "Programming the Hilbert curve", AIP Conf. Proc. 707, 381
/// (2004), https://doi.org/10.1063/1.1751381
pub fn encodeNd(bits: u8, point: []const u32) u128 {
    std.debug.assert(point.len >= 1 and point.len <= 32 and bits >= 1 and bits <= 32 and point.len * bits <= 128);
    var buf: [32]u64 = undefined;
    const x = buf[0..point.len];
    for (point, x) |c, *d| d.* = c;
    const m: u64 = @as(u64, 1) << @intCast(bits - 1);
    var q = m;
    while (q > 1) : (q >>= 1) {
        const p = q - 1;
        for (x) |*xi| {
            if (xi.* & q != 0) {
                x[0] ^= p;
            } else {
                const t = (x[0] ^ xi.*) & p;
                x[0] ^= t;
                xi.* ^= t;
            }
        }
    }
    for (1..x.len) |i| x[i] ^= x[i - 1];
    var t: u64 = 0;
    q = m;
    while (q > 1) : (q >>= 1) {
        if (x[x.len - 1] & q != 0) t ^= q - 1;
    }
    for (x) |*xi| xi.* ^= t;
    var h: u128 = 0;
    var level = bits;
    while (level > 0) {
        level -= 1;
        for (x) |xi| h = (h << 1) | ((xi >> @intCast(level)) & 1);
    }
    return h;
}

/// Inverse of `encodeNd` (Skilling's `TransposetoAxes`). Writes
/// `out.len` coordinates.
pub fn decodeNd(bits: u8, index: u128, out: []u32) void {
    std.debug.assert(out.len >= 1 and out.len <= 32 and bits >= 1 and bits <= 32 and out.len * bits <= 128);
    var buf: [32]u64 = @splat(0);
    const x = buf[0..out.len];
    var pos: u32 = @intCast(out.len * bits);
    var level = bits;
    while (level > 0) {
        level -= 1;
        for (x) |*xi| {
            pos -= 1;
            xi.* |= @as(u64, @intCast((index >> @intCast(pos)) & 1)) << @intCast(level);
        }
    }
    const n = x.len;
    const t = x[n - 1] >> 1;
    var i = n - 1;
    while (i > 0) : (i -= 1) x[i] ^= x[i - 1];
    x[0] ^= t;
    const top: u64 = @as(u64, 2) << @intCast(bits - 1);
    var q: u64 = 2;
    while (q != top) : (q <<= 1) {
        const p = q - 1;
        var j = n;
        while (j > 0) {
            j -= 1;
            if (x[j] & q != 0) {
                x[0] ^= p;
            } else {
                const s = (x[0] ^ x[j]) & p;
                x[0] ^= s;
                x[j] ^= s;
            }
        }
    }
    for (x, out) |v, *o| o.* = @intCast(v);
}

test "reference n-D round-trips" {
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    for (0..500) |_| {
        const dims = r.intRangeAtMost(u8, 1, 32);
        const bits = r.intRangeAtMost(u8, 1, @min(32, 128 / dims));
        var p: [32]u32 = undefined;
        for (p[0..dims]) |*c| c.* = if (bits == 32) r.int(u32) else r.uintLessThan(u32, @as(u32, 1) << @intCast(bits));
        var back: [32]u32 = undefined;
        decodeNd(bits, encodeNd(bits, p[0..dims]), back[0..dims]);
        try std.testing.expectEqualSlices(u32, p[0..dims], back[0..dims]);
    }
}
