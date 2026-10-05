//! Fuzz targets. `zig build test` runs each once on its corpus;
//! `zig build test --fuzz` explores further.

const std = @import("std");
const curve2d = @import("curve2d.zig");
const curvend = @import("curvend.zig");
const marker = @import("marker.zig");
const reference = @import("reference.zig");
const Smith = std.testing.Smith;

fn parseThenFormat(_: void, smith: *Smith) anyerror!void {
    var buf: [marker.Marker.max_len + 8]u8 = undefined;
    const text = buf[0..smith.slice(&buf)];
    const m = marker.Marker.parse(text) catch return;
    var out: [marker.Marker.max_len]u8 = undefined;
    try std.testing.expectEqualStrings(text, m.format(&out));
    const r = m.range(smith.value(u8));
    try std.testing.expect(r.lo.key <= m.key and m.key <= r.hi.key);
}

test "fuzz: Marker.parse accepts only canonical text" {
    try std.testing.fuzz({}, parseThenFormat, .{ .corpus = &.{
        "hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8",
        "hk1:1:1:0000000000000000:1",
        "hk1:32:4:ffffffffffffffff:ffffffffffffffffffffffffffffffff",
        "hk1:08:8:9e3779b97f4a7c15:a0c28ad75ed48ca8",
    } });
}

fn checked2d(_: void, smith: *Smith) anyerror!void {
    const bits = smith.value(u6);
    const x = smith.value(u32);
    const y = smith.value(u32);
    if (curve2d.encodeChecked(bits, x, y)) |h| {
        try std.testing.expectEqual(reference.encode2(bits, x, y), h);
        try std.testing.expectEqual(curve2d.Point{ .x = x, .y = y }, try curve2d.decodeChecked(bits, h));
    } else |err| switch (err) {
        error.OrderOutOfRange => try std.testing.expect(bits < 1 or bits > curve2d.max_bits),
        error.CoordinateOutOfRange => try std.testing.expect(bits < 32 and (x >> @intCast(bits) != 0 or y >> @intCast(bits) != 0)),
        else => return err,
    }
    const index = smith.value(u64);
    if (curve2d.decodeChecked(bits, index)) |p| {
        try std.testing.expectEqual(index, try curve2d.encodeChecked(bits, p.x, p.y));
    } else |_| {}
}

test "fuzz: checked 2D encode and decode round-trip or reject" {
    try std.testing.fuzz({}, checked2d, .{});
}

fn checkedNd(_: void, smith: *Smith) anyerror!void {
    const dims = smith.valueRangeAtMost(u8, 0, curvend.max_dims + 1);
    const bits = smith.valueRangeAtMost(u8, 0, curvend.max_bits + 1);
    var point: [curvend.max_dims + 1]u32 = undefined;
    for (&point) |*c| c.* = smith.value(u32);
    if (bits >= 1 and bits < 32) {
        if (smith.boolWeighted(1, 3)) for (&point) |*c| {
            c.* &= (@as(u32, 1) << @intCast(bits)) - 1;
        };
    }
    const p = point[0..@min(dims, point.len)];
    const h = curvend.encodeChecked(dims, bits, p) catch return;
    var back: [curvend.max_dims + 1]u32 = undefined;
    try curvend.decodeChecked(dims, bits, h, back[0..p.len]);
    try std.testing.expectEqualSlices(u32, p, back[0..p.len]);
    try std.testing.expectEqual(h, reference.encodeNd(bits, p));
}

test "fuzz: checked n-D encode and decode round-trip or reject" {
    try std.testing.fuzz({}, checkedNd, .{});
}

fn rangeNd(_: void, smith: *Smith) anyerror!void {
    const dims = smith.valueRangeAtMost(u8, 1, curvend.max_dims);
    const bits = smith.valueRangeAtMost(u8, 1, @min(curvend.max_bits, curvend.max_index_bits / dims));
    const count: usize = smith.valueRangeAtMost(u8, 1, 64);
    const total: u16 = @as(u16, dims) * bits;
    const max: u128 = if (total == 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(total)) - 1;
    const start = smith.value(u128) & max;
    var buf: [64 * curvend.max_dims]u32 = undefined;
    const out = buf[0 .. count * dims];
    curvend.decodeRangeChecked(dims, bits, start, out) catch |err| {
        try std.testing.expect(err == error.IndexOutOfRange and count - 1 > max - start);
        return;
    };
    var one: [curvend.max_dims]u32 = undefined;
    for (0..count) |i| {
        try curvend.decodeChecked(dims, bits, start + i, one[0..dims]);
        try std.testing.expectEqualSlices(u32, one[0..dims], out[i * dims ..][0..dims]);
    }
}

test "fuzz: decodeRange equals decode index by index" {
    try std.testing.fuzz({}, rangeNd, .{});
}
