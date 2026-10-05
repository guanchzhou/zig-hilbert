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

inline fn axesToTranspose(x: []u32, bits: u8) void {
    const n = x.len;
    var level: u5 = @intCast(bits - 1);
    while (level > 0) : (level -= 1) {
        const p = (@as(u32, 1) << level) - 1;
        for (0..n) |i| {
            const invert = bitMask(x[i], level);
            x[0] ^= p & invert;
            const t = (x[0] ^ x[i]) & p & ~invert;
            x[0] ^= t;
            x[i] ^= t;
        }
    }
    for (1..n) |i| x[i] ^= x[i - 1];
    var t: u32 = 0;
    level = @intCast(bits - 1);
    while (level > 0) : (level -= 1) t ^= ((@as(u32, 1) << level) - 1) & bitMask(x[n - 1], level);
    for (0..n) |i| x[i] ^= t;
}

inline fn transposeToAxes(x: []u32, bits: u8) void {
    const n = x.len;
    const t = x[n - 1] >> 1;
    var i = n - 1;
    while (i > 0) : (i -= 1) x[i] ^= x[i - 1];
    x[0] ^= t;
    var level: u5 = 1;
    while (level < bits) : (level += 1) {
        const p = (@as(u32, 1) << level) - 1;
        var j = n;
        while (j > 0) {
            j -= 1;
            const invert = bitMask(x[j], level);
            x[0] ^= p & invert;
            const s = (x[0] ^ x[j]) & p & ~invert;
            x[0] ^= s;
            x[j] ^= s;
        }
        if (level == 31) break;
    }
}

inline fn interleave(comptime I: type, x: []const u32, bits: u8) I {
    var h: I = 0;
    var level = bits;
    while (level > 0) {
        level -= 1;
        for (x) |axis| h = (h << 1) | @as(I, @intCast((axis >> @intCast(level)) & 1));
    }
    return h;
}

inline fn deinterleave(comptime I: type, h: I, x: []u32, bits: u8) void {
    @memset(x, 0);
    const n = x.len;
    var pos: u32 = @as(u32, bits) * @as(u32, @intCast(n));
    var level = bits;
    while (level > 0) {
        level -= 1;
        for (0..n) |i| {
            pos -= 1;
            x[i] |= @as(u32, @intCast((h >> @intCast(pos)) & 1)) << @intCast(level);
        }
    }
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
    return interleave(Index(dims, bits), &x, bits);
}

/// Inverse of `encode`.
pub fn decode(comptime dims: u8, comptime bits: u8, index: Index(dims, bits)) [dims]u32 {
    comptime validSpace(dims, bits) catch @compileError("unsupported space");
    var x: [dims]u32 = undefined;
    deinterleave(Index(dims, bits), index, &x, bits);
    transposeToAxes(&x, bits);
    return x;
}

/// Runtime-space encode that validates its arguments. The index is
/// zero-extended to 128 bits.
pub fn encodeChecked(dims: u8, bits: u8, point: []const u32) Error!u128 {
    try validSpace(dims, bits);
    if (point.len != dims) return error.DimensionsOutOfRange;
    var buf: [max_dims]u32 = undefined;
    const x = buf[0..dims];
    for (point, x) |c, *dst| {
        if (bits < 32 and c >> @intCast(bits) != 0) return error.CoordinateOutOfRange;
        dst.* = c;
    }
    axesToTranspose(x, bits);
    return interleave(u128, x, bits);
}

/// Runtime-space decode that validates its arguments. Writes `dims`
/// coordinates to `out`.
pub fn decodeChecked(dims: u8, bits: u8, index: u128, out: []u32) Error!void {
    try validSpace(dims, bits);
    if (out.len != dims) return error.DimensionsOutOfRange;
    const total: u16 = @as(u16, dims) * bits;
    if (total < 128 and index >> @intCast(total) != 0) return error.IndexOutOfRange;
    deinterleave(u128, index, out, bits);
    transposeToAxes(out, bits);
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
