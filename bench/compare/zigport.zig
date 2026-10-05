const std = @import("std");
const fast_hilbert = @import("fast_hilbert");
const harness = @import("harness.zig");

fn encode(x: u32, y: u32, bits: u6) u64 {
    return fast_hilbert.toHilbert(x, y, bits);
}

fn decode(h: u64, bits: u6) [2]u32 {
    const p = fast_hilbert.fromHilbert(h, bits);
    // At order 32 this port returns values above 2^32, so truncate rather than
    // assert; the harness then reports the failed round trip.
    return .{ @truncate(p.x), @truncate(p.y) };
}

pub fn main(init: std.process.Init) !void {
    try harness.run(init, "AdamSabol89/fast_hilbert", encode, decode);
}
