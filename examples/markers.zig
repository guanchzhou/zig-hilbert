const std = @import("std");
const hilbert = @import("hilbert");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var embedding: [768]f32 = undefined;
    var other: [768]f32 = undefined;
    for (&embedding, &other, 0..) |*e, *o, i| {
        e.* = @sin(@as(f32, @floatFromInt(i)));
        o.* = e.* + 0.01 * @cos(@as(f32, @floatFromInt(i * 7)));
    }

    var space = try hilbert.Space.init(gpa, .{ .input_dims = 768 }); // dims = 8, bits = 8 by default
    defer space.deinit();

    const m = try space.marker(&embedding); // []const f32, any magnitude
    var buf: [hilbert.Marker.max_len]u8 = undefined;
    const text = m.format(&buf); // "hk1:8:8:9e3779b97f4a7c15:..."

    const back = try hilbert.Marker.parse(text); // strict: rejects any non-canonical text
    const cell = back.range(3); // .lo / .hi bound the cell keeping 3 bits per axis
    std.debug.assert(cell.lo.key <= m.key and m.key <= cell.hi.key);
    const shared = hilbert.Marker.sharedPrefixBits(m, try space.marker(&other)); // null if the spaces differ
    std.debug.assert(shared.? > 0);

    const rows = try gpa.alloc(f32, 2 * 768);
    defer gpa.free(rows);
    @memcpy(rows[0..768], &embedding);
    @memcpy(rows[768..], &other);
    var keys: [2]u128 = undefined;
    try space.keys(rows, &keys, 0, null); // many embeddings in parallel; null or *usize for the failing row
    std.debug.assert(keys[0] == m.key);
}
