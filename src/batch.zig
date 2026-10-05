//! Batch encode and decode, split across cores for large batches.
//!
//! Every function takes `exec`: a thread count (0 = one per core) or a
//! `std.Io`, in which case the work is submitted to that `Io` as a task
//! group and can return `error.Canceled`.

const std = @import("std");
const curve2d = @import("curve2d.zig");
const curvend = @import("curvend.zig");
const parallel = @import("parallel.zig");

pub const Error = error{LengthMismatch};

fn Result(comptime Exec: type, comptime E: type) type {
    return (Error || E || parallel.ExecError(Exec))!void;
}

const min = parallel.min_items_per_thread;

/// `out[i] = encode(bits, xs[i], ys[i])`. Precondition: coordinates are
/// `< 2^bits`.
pub fn encode2(comptime bits: u6, xs: []const u32, ys: []const u32, out: []u64, exec: anytype) Result(@TypeOf(exec), error{}) {
    if (xs.len != ys.len or xs.len != out.len) return error.LengthMismatch;
    const Ctx = struct {
        xs: []const u32,
        ys: []const u32,
        out: []u64,
        fn run(c: *const @This(), start: usize, end: usize) void {
            for (c.xs[start..end], c.ys[start..end], c.out[start..end]) |x, y, *o| o.* = curve2d.encode(bits, x, y);
        }
    };
    const ctx: Ctx = .{ .xs = xs, .ys = ys, .out = out };
    try parallel.run(exec, out.len, min, &ctx, Ctx.run);
}

/// Inverse of `encode2`. Precondition: indices are `< 4^bits`.
pub fn decode2(comptime bits: u6, indices: []const u64, xs: []u32, ys: []u32, exec: anytype) Result(@TypeOf(exec), error{}) {
    if (xs.len != ys.len or xs.len != indices.len) return error.LengthMismatch;
    const Ctx = struct {
        in: []const u64,
        xs: []u32,
        ys: []u32,
        fn run(c: *const @This(), start: usize, end: usize) void {
            for (c.in[start..end], c.xs[start..end], c.ys[start..end]) |h, *x, *y| {
                const p = curve2d.decode(bits, h);
                x.* = p.x;
                y.* = p.y;
            }
        }
    };
    const ctx: Ctx = .{ .in = indices, .xs = xs, .ys = ys };
    try parallel.run(exec, indices.len, min, &ctx, Ctx.run);
}

/// `encode2` with a runtime order and validated coordinates. The check runs
/// inside the parallel kernel, on data it reads anyway. On error `out` is
/// unspecified.
pub fn encode2Checked(bits: u6, xs: []const u32, ys: []const u32, out: []u64, exec: anytype) Result(@TypeOf(exec), curve2d.Error) {
    if (xs.len != ys.len or xs.len != out.len) return error.LengthMismatch;
    if (bits < 1 or bits > curve2d.max_bits) return error.OrderOutOfRange;
    switch (bits) {
        inline 1...curve2d.max_bits => |b| {
            const Ctx = struct {
                xs: []const u32,
                ys: []const u32,
                out: []u64,
                bad: std.atomic.Value(bool) = .init(false),
                fn run(c: *@This(), start: usize, end: usize) void {
                    if (b < 32) {
                        var any: u32 = 0;
                        for (c.xs[start..end], c.ys[start..end]) |x, y| any |= x | y;
                        if (any >> b != 0) return c.bad.store(true, .monotonic);
                    }
                    for (c.xs[start..end], c.ys[start..end], c.out[start..end]) |x, y, *o| o.* = curve2d.encode(b, x, y);
                }
            };
            var ctx: Ctx = .{ .xs = xs, .ys = ys, .out = out };
            try parallel.run(exec, out.len, min, &ctx, Ctx.run);
            if (ctx.bad.load(.monotonic)) return error.CoordinateOutOfRange;
        },
        else => unreachable,
    }
}

/// `decode2` with a runtime order and validated indices. On error `xs` and
/// `ys` are unspecified.
pub fn decode2Checked(bits: u6, indices: []const u64, xs: []u32, ys: []u32, exec: anytype) Result(@TypeOf(exec), curve2d.Error) {
    if (xs.len != ys.len or xs.len != indices.len) return error.LengthMismatch;
    if (bits < 1 or bits > curve2d.max_bits) return error.OrderOutOfRange;
    switch (bits) {
        inline 1...curve2d.max_bits => |b| {
            const Ctx = struct {
                in: []const u64,
                xs: []u32,
                ys: []u32,
                bad: std.atomic.Value(bool) = .init(false),
                fn run(c: *@This(), start: usize, end: usize) void {
                    if (b < 32) {
                        var any: u64 = 0;
                        for (c.in[start..end]) |h| any |= h;
                        if (any >> (2 * b) != 0) return c.bad.store(true, .monotonic);
                    }
                    for (c.in[start..end], c.xs[start..end], c.ys[start..end]) |h, *x, *y| {
                        const p = curve2d.decode(b, h);
                        x.* = p.x;
                        y.* = p.y;
                    }
                }
            };
            var ctx: Ctx = .{ .in = indices, .xs = xs, .ys = ys };
            try parallel.run(exec, indices.len, min, &ctx, Ctx.run);
            if (ctx.bad.load(.monotonic)) return error.IndexOutOfRange;
        },
        else => unreachable,
    }
}

/// `encode2` over interleaved points.
pub fn encode2Points(comptime bits: u6, points: []const curve2d.Point, out: []u64, exec: anytype) Result(@TypeOf(exec), error{}) {
    if (points.len != out.len) return error.LengthMismatch;
    const Ctx = struct {
        in: []const curve2d.Point,
        out: []u64,
        fn run(c: *const @This(), start: usize, end: usize) void {
            for (c.in[start..end], c.out[start..end]) |p, *o| o.* = curve2d.encode(bits, p.x, p.y);
        }
    };
    const ctx: Ctx = .{ .in = points, .out = out };
    try parallel.run(exec, out.len, min, &ctx, Ctx.run);
}

/// Inverse of `encode2Points`.
pub fn decode2Points(comptime bits: u6, indices: []const u64, out: []curve2d.Point, exec: anytype) Result(@TypeOf(exec), error{}) {
    if (indices.len != out.len) return error.LengthMismatch;
    const Ctx = struct {
        in: []const u64,
        out: []curve2d.Point,
        fn run(c: *const @This(), start: usize, end: usize) void {
            for (c.in[start..end], c.out[start..end]) |h, *o| o.* = curve2d.decode(bits, h);
        }
    };
    const ctx: Ctx = .{ .in = indices, .out = out };
    try parallel.run(exec, out.len, min, &ctx, Ctx.run);
}

/// n-D encode of every point. Precondition: coordinates are `< 2^bits`.
pub fn encode(comptime dims: u8, comptime bits: u8, points: []const [dims]u32, out: []curvend.Index(dims, bits), exec: anytype) Result(@TypeOf(exec), error{}) {
    if (points.len != out.len) return error.LengthMismatch;
    const Ctx = struct {
        in: []const [dims]u32,
        out: []curvend.Index(dims, bits),
        fn run(c: *const @This(), start: usize, end: usize) void {
            for (c.in[start..end], c.out[start..end]) |p, *o| o.* = curvend.encode(dims, bits, p);
        }
    };
    const ctx: Ctx = .{ .in = points, .out = out };
    try parallel.run(exec, out.len, min / (@as(usize, dims) * 4), &ctx, Ctx.run);
}

/// Inverse of `encode`.
pub fn decode(comptime dims: u8, comptime bits: u8, indices: []const curvend.Index(dims, bits), out: [][dims]u32, exec: anytype) Result(@TypeOf(exec), error{}) {
    if (indices.len != out.len) return error.LengthMismatch;
    const Ctx = struct {
        in: []const curvend.Index(dims, bits),
        out: [][dims]u32,
        fn run(c: *const @This(), start: usize, end: usize) void {
            for (c.in[start..end], c.out[start..end]) |h, *o| o.* = curvend.decode(dims, bits, h);
        }
    };
    const ctx: Ctx = .{ .in = indices, .out = out };
    try parallel.run(exec, out.len, min / (@as(usize, dims) * 4), &ctx, Ctx.run);
}

test "parallel batch matches scalar encode and round-trips" {
    const n = 3 * parallel.min_items_per_thread + 11;
    const gpa = std.testing.allocator;
    const xs = try gpa.alloc(u32, n);
    defer gpa.free(xs);
    const ys = try gpa.alloc(u32, n);
    defer gpa.free(ys);
    const hs = try gpa.alloc(u64, n);
    defer gpa.free(hs);
    var prng = std.Random.DefaultPrng.init(1);
    for (xs, ys) |*x, *y| {
        x.* = prng.random().int(u32);
        y.* = prng.random().int(u32);
    }
    try encode2(32, xs, ys, hs, 4);
    for (xs, ys, hs) |x, y, h| try std.testing.expectEqual(curve2d.encode(32, x, y), h);
    const bx = try gpa.alloc(u32, n);
    defer gpa.free(bx);
    const by = try gpa.alloc(u32, n);
    defer gpa.free(by);
    try decode2(32, hs, bx, by, std.testing.io);
    try std.testing.expectEqualSlices(u32, xs, bx);
    try std.testing.expectEqualSlices(u32, ys, by);
    try std.testing.expectError(error.LengthMismatch, encode2(32, xs[1..], ys, hs, 1));

    const hc = try gpa.alloc(u64, n);
    defer gpa.free(hc);
    try encode2Checked(32, xs, ys, hc, 0);
    try std.testing.expectEqualSlices(u64, hs, hc);
    try decode2Checked(32, hc, bx, by, std.testing.io);
    try std.testing.expectEqualSlices(u32, xs, bx);

    for (xs, ys) |*x, *y| {
        x.* >>= 12;
        y.* >>= 12;
    }
    try encode2Checked(20, xs, ys, hc, 3);
    for (xs, ys, hc) |x, y, h| try std.testing.expectEqual(curve2d.encode(20, x, y), h);
    xs[n - 5] = 1 << 20;
    try std.testing.expectError(error.CoordinateOutOfRange, encode2Checked(20, xs, ys, hc, 3));
    try std.testing.expectError(error.OrderOutOfRange, encode2Checked(0, xs, ys, hc, 3));
    hc[7] = 1 << 40;
    try std.testing.expectError(error.IndexOutOfRange, decode2Checked(20, hc, bx, by, 0));

    const pts = try gpa.alloc(curve2d.Point, n);
    defer gpa.free(pts);
    for (pts, xs, ys) |*p, x, y| p.* = .{ .x = x, .y = y };
    try encode2Points(21, pts, hs, 0);
    for (pts, hs) |p, h| try std.testing.expectEqual(curve2d.encode(21, p.x, p.y), h);
    const back = try gpa.alloc(curve2d.Point, n);
    defer gpa.free(back);
    try decode2Points(21, hs, back, std.testing.io);
    try std.testing.expectEqualSlices(curve2d.Point, pts, back);
}

test "n-D batch matches scalar encode and round-trips" {
    const gpa = std.testing.allocator;
    const n = 20_000;
    const pts = try gpa.alloc([3]u32, n);
    defer gpa.free(pts);
    var prng = std.Random.DefaultPrng.init(4);
    for (pts) |*p| for (p) |*c| {
        c.* = prng.random().int(u21);
    };
    const keys = try gpa.alloc(u63, n);
    defer gpa.free(keys);
    try encode(3, 21, pts, keys, 0);
    for (pts, keys) |p, k| try std.testing.expectEqual(curvend.encode(3, 21, p), k);
    const back = try gpa.alloc([3]u32, n);
    defer gpa.free(back);
    try decode(3, 21, keys, back, std.testing.io);
    try std.testing.expectEqualSlices([3]u32, pts, back);
}
