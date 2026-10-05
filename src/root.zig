//! Hilbert curves for Zig 0.17: a table-driven 2D curve, an n-dimensional
//! curve, parallel batches, and sortable knowledge-marker keys built from
//! embeddings.
//!
//! ```zig
//! const hilbert = @import("hilbert");
//! const h = hilbert.encode2(16, 3, 5);          // comptime order 16
//! const p = hilbert.decode2(16, h);             // .{ .x = 3, .y = 5 }
//! const k = hilbert.encode(3, 10, .{ 1, 2, 3 }); // 3-D, 10 bits per axis
//! ```

const std = @import("std");

pub const curve2d = @import("curve2d.zig");
pub const curvend = @import("curvend.zig");
pub const batch = @import("batch.zig");
pub const marker = @import("marker.zig");
pub const parallel = @import("parallel.zig");
pub const reference = @import("reference.zig");

pub const Point2 = curve2d.Point;

/// 2D index on a `2^bits` grid. Precondition: `x, y < 2^bits`.
pub const encode2 = curve2d.encode;
/// Inverse of `encode2`. Precondition: `index < 4^bits`.
pub const decode2 = curve2d.decode;
/// Runtime-order 2D encode that validates its arguments.
pub const encode2Checked = curve2d.encodeChecked;
/// Runtime-order 2D decode that validates its arguments.
pub const decode2Checked = curve2d.decodeChecked;

/// n-D index; the index type is `u(dims * bits)`.
pub const encode = curvend.encode;
pub const decode = curvend.decode;
pub const encodeChecked = curvend.encodeChecked;
pub const decodeChecked = curvend.decodeChecked;

pub const Space = marker.Space;
pub const Marker = marker.Marker;
pub const KeyRange = marker.KeyRange;

test {
    _ = reference;
    _ = curve2d;
    _ = curvend;
    _ = parallel;
    _ = batch;
    _ = marker;
    _ = @import("fuzz.zig");
}

test "checked 2D API validates input" {
    try std.testing.expectEqual(@as(u64, 2), try encode2Checked(1, 1, 1));
    try std.testing.expectError(error.OrderOutOfRange, encode2Checked(0, 0, 0));
    try std.testing.expectError(error.OrderOutOfRange, encode2Checked(33, 0, 0));
    try std.testing.expectError(error.CoordinateOutOfRange, encode2Checked(4, 16, 0));
    try std.testing.expectError(error.IndexOutOfRange, decode2Checked(4, 256));
    const p = try decode2Checked(32, encode2(32, 0xffff_ffff, 0x1234_5678));
    try std.testing.expectEqual(Point2{ .x = 0xffff_ffff, .y = 0x1234_5678 }, p);
}

test "2D order 32 round-trips at the edges of the grid" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    const edges = [_]u32{ 0, 1, 0x7fff_ffff, 0x8000_0000, 0xffff_fffe, 0xffff_ffff };
    for (edges) |x| for (edges) |y| {
        const h = encode2(32, x, y);
        try std.testing.expectEqual(reference.encode2(32, x, y), h);
        try std.testing.expectEqual(Point2{ .x = x, .y = y }, decode2(32, h));
    };
    for (0..20_000) |_| {
        const x = r.int(u32);
        const y = r.int(u32);
        const h = encode2(32, x, y);
        try std.testing.expectEqual(reference.encode2(32, x, y), h);
        try std.testing.expectEqual(Point2{ .x = x, .y = y }, decode2(32, h));
    }
}

test "consecutive 2D indices are grid neighbours" {
    inline for (.{ 3, 7, 12 }) |bits| {
        var prev = decode2(bits, 0);
        try std.testing.expectEqual(Point2{ .x = 0, .y = 0 }, prev);
        const count: u64 = @as(u64, 1) << (2 * bits);
        var h: u64 = 1;
        while (h < count) : (h += 1) {
            const p = decode2(bits, h);
            const dx = if (p.x > prev.x) p.x - prev.x else prev.x - p.x;
            const dy = if (p.y > prev.y) p.y - prev.y else prev.y - p.y;
            try std.testing.expectEqual(@as(u32, 1), dx + dy);
            prev = p;
        }
        try std.testing.expectEqual(Point2{ .x = (1 << bits) - 1, .y = 0 }, prev);
    }
}

test "work per point: why the table encoder is faster than the bit loop" {
    // The bit loop runs 32 dependent iterations per order-32 point, each with
    // two data-dependent branches. The table encoder does one load per
    // `default_chunk` levels and no branches. The encode table fits the
    // 64 KiB L1 data cache of Apple Silicon efficiency cores (performance
    // cores have 128 KiB), so the loads are L1 hits once the table is warm.
    const T = curve2d.Tables(curve2d.default_chunk);
    const lookups = (32 + curve2d.default_chunk - 1) / curve2d.default_chunk;
    try std.testing.expectEqual(@as(usize, 6), lookups);
    try std.testing.expect(lookups * 5 <= 32);
    try std.testing.expect(T.bytes <= 64 * 1024 / 2);
}
