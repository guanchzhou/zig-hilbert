const std = @import("std");
const hilbert = @import("hilbert");

pub fn main() void {
    const cell = hilbert.s2.fromLatLng(37.4, -122.1) catch unreachable;
    const coarse = cell.parent(12);
    var buf: [16]u8 = undefined;
    std.debug.assert(coarse.token(&buf).len > 0);
    std.debug.assert(coarse.contains(cell));

    var ranges: [9]hilbert.s2.Range = undefined;
    const got = hilbert.s2.covering(37.4, -122.1, 1000, &ranges) catch unreachable;
    std.debug.assert(got.len >= 1);
    var inside = false;
    for (got) |r| inside = inside or (cell.id >= r.lo and cell.id <= r.hi);
    std.debug.assert(inside);

    const ring = [_]hilbert.s2.LatLng{
        .{ .lat = 37.3, .lng = -122.2 },
        .{ .lat = 37.5, .lng = -122.2 },
        .{ .lat = 37.4, .lng = -122.0 },
    };
    var cells: [32]hilbert.s2.Cell = undefined;
    const covered = hilbert.s2.coverPolygon(&ring, .{}, &cells) catch unreachable;
    std.debug.assert(covered.len >= 1);
}
