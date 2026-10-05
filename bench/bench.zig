//! `zig build bench` (always ReleaseFast). Times each 2D encoder on the
//! same random points, checks that every encoder produced the same indices,
//! and prints where the time goes. `--check` fails the run if the speedups
//! that justify the design are not met; `--quick` uses fewer points.

const std = @import("std");
const hilbert = @import("hilbert");

const curve2d = hilbert.curve2d;

const Bench = struct {
    io: std.Io,
    out: *std.Io.Writer,
    runs: usize,

    fn time(b: Bench, ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) u64 {
        var samples: [15]u64 = undefined;
        const runs = @min(b.runs, samples.len);
        f(ctx);
        for (samples[0..runs]) |*s| {
            const start = std.Io.Timestamp.now(b.io, .awake);
            f(ctx);
            const end = std.Io.Timestamp.now(b.io, .awake);
            s.* = @intCast(start.durationTo(end).nanoseconds);
        }
        std.mem.sort(u64, samples[0..runs], {}, std.sort.asc(u64));
        return samples[runs / 2];
    }

    fn report(b: Bench, name: []const u8, ns: u64, n: usize, base_ns: u64) !void {
        const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
        const speedup = @as(f64, @floatFromInt(base_ns)) / @as(f64, @floatFromInt(ns));
        try b.out.print("  {s:<34} {d:>8.3} ns/pt  {d:>8.1} Mpt/s  {d:>6.1}x\n", .{ name, per, 1000.0 / per, speedup });
    }
};

/// Same generator as `bench/compare`, so every implementation sees the same
/// points: xorshift64* seeded with 0x1234567, x from the high half, y from
/// the low half.
fn fillPoints(xs: []u32, ys: []u32, bits: u6) void {
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

fn checksum(hs: []const u64) u64 {
    var acc: u64 = 0;
    for (hs, 0..) |h, i| acc +%= h *% (@as(u64, i) | 1);
    return acc;
}

fn Encoders(comptime bits: u6) type {
    return struct {
        xs: []const u32,
        ys: []const u32,
        out: []u64,

        fn reference(c: *const @This()) void {
            for (c.xs, c.ys, c.out) |x, y, *o| o.* = hilbert.reference.encode2(bits, x, y);
        }

        fn table(comptime chunk: u4) fn (*const @This()) void {
            return struct {
                fn f(c: *const Encoders(bits)) void {
                    for (c.xs, c.ys, c.out) |x, y, *o| o.* = curve2d.encodeWith(chunk, bits, x, y);
                }
            }.f;
        }

        fn lanes(c: *const @This()) void {
            const L = 8;
            var i: usize = 0;
            while (i + L <= c.xs.len) : (i += L) {
                const x: @Vector(L, u32) = c.xs[i..][0..L].*;
                const y: @Vector(L, u32) = c.ys[i..][0..L].*;
                c.out[i..][0..L].* = curve2d.encodeLanes(L, bits, x, y);
            }
            while (i < c.xs.len) : (i += 1) c.out[i] = curve2d.encode(bits, c.xs[i], c.ys[i]);
        }

        fn parallelAll(c: *const @This()) void {
            hilbert.batch.encode2(bits, c.xs, c.ys, c.out, 0) catch unreachable;
        }
    };
}

fn Decoders(comptime bits: u6) type {
    return struct {
        in: []const u64,
        xs: []u32,
        ys: []u32,

        fn reference(c: *const @This()) void {
            for (c.in, c.xs, c.ys) |h, *x, *y| {
                const p = hilbert.reference.decode2(bits, h);
                x.* = p[0];
                y.* = p[1];
            }
        }

        fn table(c: *const @This()) void {
            for (c.in, c.xs, c.ys) |h, *x, *y| {
                const p = curve2d.decode(bits, h);
                x.* = p.x;
                y.* = p.y;
            }
        }

        fn parallelAll(c: *const @This()) void {
            hilbert.batch.decode2(bits, c.in, c.xs, c.ys, 0) catch unreachable;
        }
    };
}

const Results = struct {
    reference_ns: u64 = 0,
    default_ns: u64 = 0,
    parallel_ns: u64 = 0,
};

fn run2d(b: Bench, comptime bits: u6, gpa: std.mem.Allocator, n: usize) !Results {
    const xs = try gpa.alloc(u32, n);
    defer gpa.free(xs);
    const ys = try gpa.alloc(u32, n);
    defer gpa.free(ys);
    const out = try gpa.alloc(u64, n);
    defer gpa.free(out);
    fillPoints(xs, ys, bits);

    const E = Encoders(bits);
    const ctx: E = .{ .xs = xs, .ys = ys, .out = out };
    var res: Results = .{};

    try b.out.print("\n2D encode, order {d}, {d} points\n", .{ bits, n });
    res.reference_ns = b.time(&ctx, E.reference);
    const want = checksum(out);
    try b.report("bit loop (reference)", res.reference_ns, n, res.reference_ns);
    inline for (1..7) |chunk| {
        const ns = b.time(&ctx, E.table(chunk));
        if (checksum(out) != want) return error.ChecksumMismatch;
        if (chunk == curve2d.default_chunk) res.default_ns = ns;
        const T = curve2d.Tables(chunk);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "table {d} bits/lookup ({d} B, {d} loads)", .{ chunk, T.bytes, (bits + chunk - 1) / chunk });
        try b.report(name, ns, n, res.reference_ns);
    }
    const lanes_ns = b.time(&ctx, E.lanes);
    if (checksum(out) != want) return error.ChecksumMismatch;
    try b.report("NEON per-bit, 8 lanes", lanes_ns, n, res.reference_ns);
    res.parallel_ns = b.time(&ctx, E.parallelAll);
    if (checksum(out) != want) return error.ChecksumMismatch;
    var name_buf: [64]u8 = undefined;
    const threads = hilbert.parallel.threadCount(n, 0, hilbert.parallel.min_items_per_thread);
    try b.report(try std.fmt.bufPrint(&name_buf, "batch.encode2, {d} threads", .{threads}), res.parallel_ns, n, res.reference_ns);
    try b.out.print("  checksum {x:0>16}\n", .{want});

    const D = Decoders(bits);
    const bx = try gpa.alloc(u32, n);
    defer gpa.free(bx);
    const by = try gpa.alloc(u32, n);
    defer gpa.free(by);
    const dctx: D = .{ .in = out, .xs = bx, .ys = by };
    try b.out.print("2D decode, order {d}\n", .{bits});
    const dref = b.time(&dctx, D.reference);
    try b.report("bit loop (reference)", dref, n, dref);
    const dtab = b.time(&dctx, D.table);
    if (!std.mem.eql(u32, xs, bx) or !std.mem.eql(u32, ys, by)) return error.ChecksumMismatch;
    try b.report("table (default)", dtab, n, dref);
    const dpar = b.time(&dctx, D.parallelAll);
    if (!std.mem.eql(u32, xs, bx) or !std.mem.eql(u32, ys, by)) return error.ChecksumMismatch;
    try b.report("batch.decode2, all cores", dpar, n, dref);
    return res;
}

fn runNd(b: Bench, gpa: std.mem.Allocator, n: usize) !void {
    try b.out.print("\nn-D encode (Skilling transpose, branch-free)\n", .{});
    inline for (.{ .{ 3, 21 }, .{ 8, 8 }, .{ 16, 8 } }) |s| {
        const dims = s[0];
        const bits = s[1];
        const pts = try gpa.alloc([dims]u32, n);
        defer gpa.free(pts);
        const out = try gpa.alloc(hilbert.curvend.Index(dims, bits), n);
        defer gpa.free(out);
        var prng = std.Random.DefaultPrng.init(5);
        for (pts) |*p| for (p) |*c| {
            c.* = prng.random().int(u32) >> (32 - bits);
        };
        const Ctx = struct {
            pts: [][dims]u32,
            out: []hilbert.curvend.Index(dims, bits),
            fn f(c: *const @This()) void {
                for (c.pts, c.out) |p, *o| o.* = hilbert.encode(dims, bits, p);
            }
        };
        const ctx: Ctx = .{ .pts = pts, .out = out };
        const ns = b.time(&ctx, Ctx.f);
        var name_buf: [64]u8 = undefined;
        try b.report(try std.fmt.bufPrint(&name_buf, "{d} dims x {d} bits ({d}-bit key)", .{ dims, bits, dims * bits }), ns, n, ns);
    }
}

fn runMarkers(b: Bench, gpa: std.mem.Allocator, rows: usize) !void {
    const width = 768;
    try b.out.print("\nKnowledge-marker keys, {d}-dim embeddings, {d} rows\n", .{ width, rows });
    var space = try hilbert.Space.init(gpa, .{ .input_dims = width });
    defer space.deinit();
    const data = try gpa.alloc(f32, rows * width);
    defer gpa.free(data);
    var prng = std.Random.DefaultPrng.init(11);
    for (data) |*v| v.* = prng.random().floatNorm(f32);
    const out = try gpa.alloc(u128, rows);
    defer gpa.free(out);
    const Ctx = struct {
        space: *const hilbert.Space,
        data: []const f32,
        out: []u128,
        threads: usize,
        fn f(c: *const @This()) void {
            c.space.keys(c.data, c.out, c.threads) catch unreachable;
        }
    };
    const one: Ctx = .{ .space = &space, .data = data, .out = out, .threads = 1 };
    const t1 = b.time(&one, Ctx.f);
    try b.report("8 dims x 8 bits, 1 thread", t1, rows, t1);
    const all: Ctx = .{ .space = &space, .data = data, .out = out, .threads = 0 };
    const tn = b.time(&all, Ctx.f);
    try b.report("8 dims x 8 bits, all cores", tn, rows, t1);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var check = false;
    var quick = false;
    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) check = true else if (std.mem.eql(u8, arg, "--quick")) quick = true else {
            std.debug.print("unknown argument: {s}\nusage: bench [--quick] [--check]\n", .{arg});
            std.process.exit(2);
        }
    }

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const out = &stdout.interface;
    const b: Bench = .{ .io = init.io, .out = out, .runs = if (quick) 5 else 9 };
    const n: usize = if (quick) 1 << 20 else 1 << 23;

    const cores = std.Thread.getCpuCount() catch 1;
    try out.print("zig-hilbert bench, {d} logical cores, median of {d} runs\n", .{ cores, b.runs });
    const r32 = try run2d(b, 32, gpa, n);
    _ = try run2d(b, 16, gpa, n);
    try runNd(b, gpa, n / 8);
    try runMarkers(b, gpa, if (quick) 1 << 13 else 1 << 16);

    const T = curve2d.Tables(curve2d.default_chunk);
    try out.print(
        \\
        \\Why the default encoder is faster (order 32):
        \\  bit loop: 32 dependent iterations per point, each with two data-dependent
        \\    branches that mispredict on random input.
        \\  table:    {d} loads per point from a {d}-byte table generated at compile
        \\    time ({d} bit levels per load), no branches, no heap state. The table
        \\    stays in L1 (64-128 KiB per Apple Silicon core), and independent points
        \\    overlap in the out-of-order core.
        \\  batch:    the same kernel split over every core (performance and
        \\    efficiency cores on Apple Silicon).
        \\
    , .{ (32 + curve2d.default_chunk - 1) / curve2d.default_chunk, T.bytes, curve2d.default_chunk });
    try out.flush();

    if (check) {
        const single = @as(f64, @floatFromInt(r32.reference_ns)) / @as(f64, @floatFromInt(r32.default_ns));
        const multi = @as(f64, @floatFromInt(r32.default_ns)) / @as(f64, @floatFromInt(r32.parallel_ns));
        var failed = false;
        if (single < 2.0) {
            std.debug.print("check failed: table encoder is only {d:.2}x faster than the bit loop (need 2x)\n", .{single});
            failed = true;
        }
        if (cores > 1 and multi < 1.5) {
            std.debug.print("check failed: parallel batch is only {d:.2}x faster than one thread (need 1.5x)\n", .{multi});
            failed = true;
        }
        if (failed) std.process.exit(1);
        try out.print("check passed: table {d:.1}x over bit loop, batch {d:.1}x over one thread\n", .{ single, multi });
        try out.flush();
    }
}
