const std = @import("std");
const hcc = @import("hilbertcurve");
const hilbert = @import("hilbert");
const harness = @import("harness.zig");

var domains: [2]*hcc.domain.Domain = undefined;

fn domainFor(bits: u6) *const hcc.domain.Domain {
    return domains[@intFromBool(bits == 16)];
}

fn create(axis_bits: []const u32) !*hcc.domain.Domain {
    const desc = hcc.domain.DomainDesc{
        .struct_size = @sizeOf(hcc.domain.DomainDesc),
        .n = @intCast(axis_bits.len),
        .axis_bits = axis_bits.ptr,
        .axis_sizes = null,
        .axis_policy = .sorted,
        .axis_permutation = null,
        .gray_family = .brgc_rotated,
        .path_family = .brgc_standard,
        .seed = 0,
        .max_k_for_tables = 0,
        .flags = 0,
    };
    var dom: ?*hcc.domain.Domain = null;
    if (hcc.domain.domainCreate(&desc, &dom, std.heap.page_allocator) != .ok) return error.DomainInitFailed;
    return dom.?;
}

fn encode(x: u32, y: u32, bits: u6) u64 {
    var out: [1]u64 = undefined;
    _ = hcc.hilbert_affine.encode(domainFor(bits), &.{ x, y }, &out);
    return out[0];
}

fn decode(h: u64, bits: u6) [2]u32 {
    var out: [2]u64 = undefined;
    _ = hcc.hilbert_affine.decode(domainFor(bits), &.{h}, &out);
    return .{ @truncate(out[0]), @truncate(out[1]) };
}

/// Its batch entry point, `encode_points`, on interleaved u64 coordinates.
fn batch(init: std.process.Init, out: *std.Io.Writer, n: usize) !void {
    const gpa = init.gpa;
    const xs = try gpa.alloc(u32, n);
    defer gpa.free(xs);
    const ys = try gpa.alloc(u32, n);
    defer gpa.free(ys);
    const coords = try gpa.alloc(u64, 2 * n);
    defer gpa.free(coords);
    const hs = try gpa.alloc(u64, n);
    defer gpa.free(hs);
    inline for (.{ 32, 16 }) |bits| {
        harness.points(xs, ys, bits);
        for (xs, ys, 0..) |x, y, i| coords[2 * i ..][0..2].* = .{ x, y };
        const Ctx = struct {
            coords: []const u64,
            hs: []u64,
            fn enc(c: *const @This()) void {
                _ = hcc.hilbert_affine.encode_points(domainFor(bits), c.coords, c.hs.len, c.hs);
            }
        };
        const ctx: Ctx = .{ .coords = coords, .hs = hs };
        const e = harness.median(init.io, &ctx, Ctx.enc) / @as(f64, @floatFromInt(n));
        try out.print("adolgert/HilbertCurveCompact encode_points {d} {d:.3} {x:0>16}\n", .{ bits, e, harness.checksum(hs) });
    }
}

/// n-D against zig-hilbert on the same inputs. The two libraries use
/// different n-D curves (only 2D coincides), so this compares speed and
/// checks each library's own round trip.
fn nd(init: std.process.Init, out: *std.Io.Writer, comptime dims: u8, comptime bits: u8) !void {
    const gpa = init.gpa;
    const n = 1 << 16;
    const axis_bits: [dims]u32 = @splat(bits);
    const dom = try create(&axis_bits);
    const words = dom.index_words;
    const I = hilbert.curvend.Index(dims, bits);

    const pts = try gpa.alloc([dims]u32, n);
    defer gpa.free(pts);
    const pts64 = try gpa.alloc([dims]u64, n);
    defer gpa.free(pts64);
    var prng = std.Random.DefaultPrng.init(0x1234567);
    for (pts, pts64) |*p, *q| for (p, q) |*c, *d| {
        c.* = if (bits == 32) prng.random().int(u32) else prng.random().uintLessThan(u32, @as(u32, 1) << bits);
        d.* = c.*;
    };
    const theirs = try gpa.alloc([2]u64, n);
    defer gpa.free(theirs);
    const ours = try gpa.alloc(I, n);
    defer gpa.free(ours);
    const back64 = try gpa.alloc([dims]u64, n);
    defer gpa.free(back64);
    const back = try gpa.alloc([dims]u32, n);
    defer gpa.free(back);

    const Ctx = struct {
        dom: *const hcc.domain.Domain,
        words: usize,
        pts: [][dims]u32,
        pts64: [][dims]u64,
        theirs: [][2]u64,
        ours: []I,
        back64: [][dims]u64,
        back: [][dims]u32,
        fn encTheirs(c: *const @This()) void {
            for (c.pts64, c.theirs) |*p, *h| _ = hcc.hilbert_affine.encode(c.dom, p, h[0..c.words]);
        }
        fn encOurs(c: *const @This()) void {
            for (c.pts, c.ours) |p, *h| h.* = hilbert.encode(dims, bits, p);
        }
        fn decTheirs(c: *const @This()) void {
            for (c.theirs, c.back64) |*h, *p| _ = hcc.hilbert_affine.decode(c.dom, h[0..c.words], p);
        }
        fn decOurs(c: *const @This()) void {
            for (c.ours, c.back) |h, *p| p.* = hilbert.decode(dims, bits, h);
        }
        fn rangeTheirs(c: *const @This()) void {
            const start: [2]u64 = .{ 0, 0 };
            _ = hcc.hilbert_affine.decode_range(c.dom, start[0..c.words], c.back64.len, @as([*]u64, @ptrCast(c.back64.ptr))[0 .. c.back64.len * dims]);
        }
        fn rangeOurs(c: *const @This()) void {
            hilbert.decodeRange(dims, bits, 0, c.back);
        }
    };
    @memset(theirs, .{ 0, 0 });
    const ctx: Ctx = .{ .dom = dom, .words = words, .pts = pts, .pts64 = pts64, .theirs = theirs, .ours = ours, .back64 = back64, .back = back };
    const per = @as(f64, @floatFromInt(n));
    const enc_t = harness.median(init.io, &ctx, Ctx.encTheirs) / per;
    const enc_o = harness.median(init.io, &ctx, Ctx.encOurs) / per;
    const dec_t = harness.median(init.io, &ctx, Ctx.decTheirs) / per;
    const dec_o = harness.median(init.io, &ctx, Ctx.decOurs) / per;
    var ok = true;
    for (pts, pts64, back, back64) |p, q, b, b64| {
        if (!std.mem.eql(u32, &p, &b) or !std.mem.eql(u64, &q, &b64)) ok = false;
    }
    const range_t = harness.median(init.io, &ctx, Ctx.rangeTheirs) / per;
    const range_o = harness.median(init.io, &ctx, Ctx.rangeOurs) / per;
    for (back, 0..) |p, i| {
        if (!std.mem.eql(u32, &p, &hilbert.decode(dims, bits, @intCast(i)))) ok = false;
    }
    try out.print("nd {d}x{d} encode theirs {d:.1} ours {d:.1} | decode theirs {d:.1} ours {d:.1} | consecutive theirs {d:.1} ours {d:.1} | {s}\n", .{
        dims, bits, enc_t, enc_o, dec_t, dec_o, range_t, range_o, if (ok) "roundtrip-ok" else "ROUNDTRIP-FAILED",
    });
}

pub fn main(init: std.process.Init) !void {
    domains = .{ try create(&.{ 32, 32 }), try create(&.{ 16, 16 }) };
    try harness.run(init, "adolgert/HilbertCurveCompact", encode, decode);
    var it = init.minimal.args.iterate();
    _ = it.skip();
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    try batch(init, out, try std.fmt.parseInt(usize, it.next() orelse "8388608", 10));
    inline for (.{ .{ 3, 21 }, .{ 4, 16 }, .{ 8, 8 }, .{ 4, 32 }, .{ 16, 8 } }) |s| try nd(init, out, s[0], s[1]);
    try out.flush();
}
