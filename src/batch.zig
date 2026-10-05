//! Batch 2D encode and decode over structure-of-arrays input, split across
//! cores for large batches.

const std = @import("std");
const curve2d = @import("curve2d.zig");
const parallel = @import("parallel.zig");

pub const Error = error{LengthMismatch};

/// `out[i] = encode(bits, xs[i], ys[i])`. `threads` is the thread count, or
/// 0 for one per core. Precondition: coordinates are `< 2^bits`.
pub fn encode2(comptime bits: u6, xs: []const u32, ys: []const u32, out: []u64, threads: usize) Error!void {
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
    parallel.forEachRange(out.len, threads, parallel.min_items_per_thread, &ctx, Ctx.run);
}

/// Inverse of `encode2`. Precondition: indices are `< 4^bits`.
pub fn decode2(comptime bits: u6, indices: []const u64, xs: []u32, ys: []u32, threads: usize) Error!void {
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
    parallel.forEachRange(indices.len, threads, parallel.min_items_per_thread, &ctx, Ctx.run);
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
    try decode2(32, hs, bx, by, 4);
    try std.testing.expectEqualSlices(u32, xs, bx);
    try std.testing.expectEqualSlices(u32, ys, by);
    try std.testing.expectError(error.LengthMismatch, encode2(32, xs[1..], ys, hs, 1));
}
