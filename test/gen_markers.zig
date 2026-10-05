//! Writes the golden marker vectors to stdout. `zig build golden` stores
//! them in `test/markers.jsonl`; regenerate only on a deliberate format
//! change (which also needs a new marker version prefix).

const std = @import("std");
const hilbert = @import("hilbert");

const Shape = struct { input_dims: u32, dims: u8, bits: u8, seed: u64 = hilbert.marker.default_seed };

const shapes = [_]Shape{
    .{ .input_dims = 3, .dims = 8, .bits = 8 },
    .{ .input_dims = 16, .dims = 8, .bits = 8 },
    .{ .input_dims = 64, .dims = 4, .bits = 16 },
    .{ .input_dims = 384, .dims = 8, .bits = 8 },
    .{ .input_dims = 768, .dims = 16, .bits = 8 },
    .{ .input_dims = 5, .dims = 1, .bits = 32 },
    .{ .input_dims = 10, .dims = 32, .bits = 4 },
    .{ .input_dims = 7, .dims = 3, .bits = 10, .seed = 1 },
    .{ .input_dims = 100, .dims = 2, .bits = 32, .seed = 0xdeadbeef },
    .{ .input_dims = 33, .dims = 8, .bits = 16, .seed = 0 },
};

/// Scale exponents applied to the base vectors; powers of two keep the key.
const scales = [_]i32{ 0, 0, 0, 100, -100 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var buf: [1 << 16]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    for (shapes, 0..) |shape, si| {
        var space = try hilbert.Space.init(gpa, .{ .input_dims = shape.input_dims, .dims = shape.dims, .bits = shape.bits, .seed = shape.seed });
        defer space.deinit();
        const e = try gpa.alloc(f32, shape.input_dims);
        defer gpa.free(e);
        for (scales, 0..) |scale, vi| {
            for (e, 0..) |*v, i| {
                const r = hilbert.marker.splitmix64(si * 31 + vi, i) % 2001;
                const base = @as(f32, @floatFromInt(@as(i32, @intCast(r)) - 1000)) / 256;
                v.* = std.math.ldexp(base, scale);
            }
            try writeCase(out, &space, shape, e);
        }
    }
    const zero: [4]f32 = @splat(0);
    var space = try hilbert.Space.init(gpa, .{ .input_dims = 4 });
    defer space.deinit();
    try writeCase(out, &space, .{ .input_dims = 4, .dims = 8, .bits = 8 }, &zero);
    try out.flush();
}

fn writeCase(out: *std.Io.Writer, space: *const hilbert.Space, shape: Shape, e: []const f32) !void {
    try out.print("{{\"input_dims\":{d},\"dims\":{d},\"bits\":{d},\"seed\":\"{x:0>16}\",\"embedding\":[", .{ shape.input_dims, shape.dims, shape.bits, shape.seed });
    for (e, 0..) |v, i| try out.print("{s}{e}", .{ if (i == 0) "" else ",", v });
    if (space.marker(e)) |m| {
        var text: [hilbert.Marker.max_len]u8 = undefined;
        try out.print("],\"marker\":\"{s}\"}}\n", .{m.format(&text)});
    } else |err| {
        try out.print("],\"error\":\"{s}\"}}\n", .{@errorName(err)});
    }
}
