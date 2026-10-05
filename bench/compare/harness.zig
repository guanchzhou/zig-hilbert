//! Shared timing loop for the Zig side of `bench/compare/run.sh`. It uses the
//! same point generator, checksum, and run count as `rust/src/main.rs`.

const std = @import("std");

pub const runs = 9;

pub fn points(xs: []u32, ys: []u32, bits: u6) void {
    var s: u64 = 0x1234567;
    const shift: u5 = @intCast(32 - @as(u32, bits));
    for (xs, ys) |*x, *y| {
        s ^= s >> 12;
        s ^= s << 25;
        s ^= s >> 27;
        const r = s *% 0x2545F4914F6CDD1D;
        x.* = @as(u32, @truncate(r >> 32)) >> shift;
        y.* = @as(u32, @truncate(r)) >> shift;
    }
}

pub fn checksum(hs: []const u64) u64 {
    var acc: u64 = 0;
    for (hs, 0..) |h, i| acc +%= h *% (@as(u64, i) | 1);
    return acc;
}

pub fn median(io: std.Io, ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) f64 {
    var samples: [runs]u64 = undefined;
    f(ctx);
    for (&samples) |*s| {
        const start = std.Io.Timestamp.now(io, .awake);
        f(ctx);
        s.* = @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return @floatFromInt(samples[runs / 2]);
}

/// Prints `name encode|decode bits ns_per_point checksum` lines.
pub fn run(
    init: std.process.Init,
    name: []const u8,
    comptime encode: anytype,
    comptime decode: anytype,
) !void {
    var it = init.minimal.args.iterate();
    _ = it.skip();
    const n = try std.fmt.parseInt(usize, it.next() orelse "8388608", 10);
    const gpa = init.gpa;
    const xs = try gpa.alloc(u32, n);
    defer gpa.free(xs);
    const ys = try gpa.alloc(u32, n);
    defer gpa.free(ys);
    const hs = try gpa.alloc(u64, n);
    defer gpa.free(hs);
    const bx = try gpa.alloc(u32, n);
    defer gpa.free(bx);
    const by = try gpa.alloc(u32, n);
    defer gpa.free(by);
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;

    inline for (.{ 32, 16 }) |bits| {
        points(xs, ys, bits);
        const Ctx = struct {
            xs: []u32,
            ys: []u32,
            hs: []u64,
            bx: []u32,
            by: []u32,
            fn enc(c: *const @This()) void {
                for (c.xs, c.ys, c.hs) |x, y, *h| h.* = encode(x, y, bits);
            }
            fn dec(c: *const @This()) void {
                for (c.hs, c.bx, c.by) |h, *x, *y| {
                    const p = decode(h, bits);
                    x.* = p[0];
                    y.* = p[1];
                }
            }
        };
        const ctx: Ctx = .{ .xs = xs, .ys = ys, .hs = hs, .bx = bx, .by = by };
        const e = median(init.io, &ctx, Ctx.enc) / @as(f64, @floatFromInt(n));
        const sum = checksum(hs);
        const d = median(init.io, &ctx, Ctx.dec) / @as(f64, @floatFromInt(n));
        const ok = std.mem.eql(u32, xs, bx) and std.mem.eql(u32, ys, by);
        try out.print("{s} encode {d} {d:.3} {x:0>16}\n", .{ name, bits, e, sum });
        try out.print("{s} decode {d} {d:.3} {s}\n", .{ name, bits, d, if (ok) "roundtrip-ok" else "ROUNDTRIP-FAILED" });
    }
    try out.flush();
}
