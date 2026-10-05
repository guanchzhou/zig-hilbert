//! Fuzz targets. `zig build test` runs every input in `src/fuzz-corpus/`;
//! `zig build test --fuzz` explores further and keeps new inputs in the
//! build cache. Copy any input that finds a bug back into the corpus.

const std = @import("std");
const curve2d = @import("curve2d.zig");
const curvend = @import("curvend.zig");
const marker = @import("marker.zig");
const reference = @import("reference.zig");
const Smith = std.testing.Smith;

const marker_corpus = [_][]const u8{
    @embedFile("fuzz-corpus/marker/00"),
    @embedFile("fuzz-corpus/marker/01"),
    @embedFile("fuzz-corpus/marker/02"),
    @embedFile("fuzz-corpus/marker/03"),
    @embedFile("fuzz-corpus/marker/04"),
    @embedFile("fuzz-corpus/marker/05"),
    @embedFile("fuzz-corpus/marker/06"),
    @embedFile("fuzz-corpus/marker/07"),
    @embedFile("fuzz-corpus/marker/08"),
    @embedFile("fuzz-corpus/marker/09"),
    @embedFile("fuzz-corpus/marker/10"),
    @embedFile("fuzz-corpus/marker/11"),
    @embedFile("fuzz-corpus/marker/12"),
    @embedFile("fuzz-corpus/marker/13"),
};

const checked2d_corpus = [_][]const u8{
    @embedFile("fuzz-corpus/checked2d/00"),
    @embedFile("fuzz-corpus/checked2d/01"),
    @embedFile("fuzz-corpus/checked2d/02"),
    @embedFile("fuzz-corpus/checked2d/03"),
    @embedFile("fuzz-corpus/checked2d/04"),
    @embedFile("fuzz-corpus/checked2d/05"),
    @embedFile("fuzz-corpus/checked2d/06"),
    @embedFile("fuzz-corpus/checked2d/07"),
    @embedFile("fuzz-corpus/checked2d/08"),
    @embedFile("fuzz-corpus/checked2d/09"),
    @embedFile("fuzz-corpus/checked2d/10"),
    @embedFile("fuzz-corpus/checked2d/11"),
    @embedFile("fuzz-corpus/checked2d/12"),
    @embedFile("fuzz-corpus/checked2d/13"),
    @embedFile("fuzz-corpus/checked2d/14"),
    @embedFile("fuzz-corpus/checked2d/15"),
    @embedFile("fuzz-corpus/checked2d/16"),
    @embedFile("fuzz-corpus/checked2d/17"),
    @embedFile("fuzz-corpus/checked2d/18"),
    @embedFile("fuzz-corpus/checked2d/19"),
    @embedFile("fuzz-corpus/checked2d/20"),
};

const checkednd_corpus = [_][]const u8{
    @embedFile("fuzz-corpus/checkednd/00"),
    @embedFile("fuzz-corpus/checkednd/01"),
    @embedFile("fuzz-corpus/checkednd/02"),
    @embedFile("fuzz-corpus/checkednd/03"),
    @embedFile("fuzz-corpus/checkednd/04"),
    @embedFile("fuzz-corpus/checkednd/05"),
    @embedFile("fuzz-corpus/checkednd/06"),
    @embedFile("fuzz-corpus/checkednd/07"),
    @embedFile("fuzz-corpus/checkednd/08"),
    @embedFile("fuzz-corpus/checkednd/09"),
    @embedFile("fuzz-corpus/checkednd/10"),
    @embedFile("fuzz-corpus/checkednd/11"),
    @embedFile("fuzz-corpus/checkednd/12"),
    @embedFile("fuzz-corpus/checkednd/13"),
    @embedFile("fuzz-corpus/checkednd/14"),
    @embedFile("fuzz-corpus/checkednd/15"),
    @embedFile("fuzz-corpus/checkednd/16"),
    @embedFile("fuzz-corpus/checkednd/17"),
    @embedFile("fuzz-corpus/checkednd/18"),
    @embedFile("fuzz-corpus/checkednd/19"),
    @embedFile("fuzz-corpus/checkednd/20"),
};

const range_corpus = [_][]const u8{
    @embedFile("fuzz-corpus/range/00"),
    @embedFile("fuzz-corpus/range/01"),
    @embedFile("fuzz-corpus/range/02"),
    @embedFile("fuzz-corpus/range/03"),
    @embedFile("fuzz-corpus/range/04"),
    @embedFile("fuzz-corpus/range/05"),
    @embedFile("fuzz-corpus/range/06"),
    @embedFile("fuzz-corpus/range/07"),
    @embedFile("fuzz-corpus/range/08"),
    @embedFile("fuzz-corpus/range/09"),
    @embedFile("fuzz-corpus/range/10"),
    @embedFile("fuzz-corpus/range/11"),
    @embedFile("fuzz-corpus/range/12"),
    @embedFile("fuzz-corpus/range/13"),
    @embedFile("fuzz-corpus/range/14"),
    @embedFile("fuzz-corpus/range/15"),
    @embedFile("fuzz-corpus/range/16"),
    @embedFile("fuzz-corpus/range/17"),
    @embedFile("fuzz-corpus/range/18"),
    @embedFile("fuzz-corpus/range/19"),
    @embedFile("fuzz-corpus/range/20"),
};

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
    try std.testing.fuzz({}, parseThenFormat, .{ .corpus = &marker_corpus });
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
    try std.testing.fuzz({}, checked2d, .{ .corpus = &checked2d_corpus });
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
    try std.testing.fuzz({}, checkedNd, .{ .corpus = &checkednd_corpus });
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
    try std.testing.fuzz({}, rangeNd, .{ .corpus = &range_corpus });
}
