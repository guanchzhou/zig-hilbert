const std = @import("std");
const hilbert = @import("hilbert");

pub fn main(init: std.process.Init) !void {
    // 2D, order known at compile time: no checks, no branches.
    const d = hilbert.encode2(16, 12345, 54321); // u64
    const p = hilbert.decode2(16, d); // .{ .x, .y }
    std.debug.assert(p.x == 12345 and p.y == 54321);

    // 2D, order and coordinates from untrusted input.
    const d2 = try hilbert.encode2Checked(16, 12345, 54321);
    const p2 = try hilbert.decode2Checked(16, d2);
    std.debug.assert(d2 == d and p2.x == p.x);
    if (hilbert.encode2Checked(4, 16, 0)) |_| unreachable else |err| std.debug.assert(err == error.CoordinateOutOfRange);

    // Millions of points on every core (threads = 0 means one per core).
    const gpa = init.gpa;
    const n = 1 << 20;
    const xs = try gpa.alloc(u32, n);
    defer gpa.free(xs);
    const ys = try gpa.alloc(u32, n);
    defer gpa.free(ys);
    const out = try gpa.alloc(u64, n);
    defer gpa.free(out);
    for (xs, ys, 0..) |*x, *y, i| {
        x.* = @truncate(i *% 2654435761);
        y.* = @truncate(i);
    }
    try hilbert.batch.encode2(32, xs, ys, out, 0);
    try hilbert.batch.decode2(32, out, xs, ys, 0);

    // n-D: the index type is exactly dims * bits wide (u24 here).
    const k = hilbert.encode(3, 8, .{ 10, 200, 37 });
    const pt = hilbert.decode(3, 8, k); // [3]u32
    std.debug.assert(pt[1] == 200);
    const k2 = try hilbert.encodeChecked(3, 8, &.{ 10, 200, 37 }); // runtime shape, u128
    std.debug.assert(k2 == k);

    // Walk the curve: consecutive indices, decoded incrementally.
    var walk: [256][3]u32 = undefined;
    hilbert.decodeRange(3, 8, 1000, &walk); // walk[i] = decode(3, 8, 1000 + i)
    std.debug.assert(std.mem.eql(u32, &walk[5], &hilbert.decode(3, 8, 1005)));
}
