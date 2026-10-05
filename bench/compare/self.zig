const std = @import("std");
const hilbert = @import("hilbert");
const harness = @import("harness.zig");

fn encode(x: u32, y: u32, comptime bits: u6) u64 {
    return hilbert.encode2(bits, x, y);
}

fn decode(h: u64, comptime bits: u6) [2]u32 {
    const p = hilbert.decode2(bits, h);
    return .{ p.x, p.y };
}

pub fn main(init: std.process.Init) !void {
    try harness.run(init, "zig-hilbert", encode, decode);
}
