const std = @import("std");
const hcc = @import("hilbertcurve");
const harness = @import("harness.zig");

var domains: [2]*hcc.domain.Domain = undefined;

fn domainFor(bits: u6) *const hcc.domain.Domain {
    return domains[@intFromBool(bits == 16)];
}

fn create(bits: u32) !*hcc.domain.Domain {
    const axis_bits = [2]u32{ bits, bits };
    const desc = hcc.domain.DomainDesc{
        .struct_size = @sizeOf(hcc.domain.DomainDesc),
        .n = 2,
        .axis_bits = &axis_bits,
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
fn batch(init: std.process.Init, n: usize) !void {
    const gpa = init.gpa;
    const xs = try gpa.alloc(u32, n);
    defer gpa.free(xs);
    const ys = try gpa.alloc(u32, n);
    defer gpa.free(ys);
    const coords = try gpa.alloc(u64, 2 * n);
    defer gpa.free(coords);
    const hs = try gpa.alloc(u64, n);
    defer gpa.free(hs);
    var buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
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
        try stdout.interface.print("adolgert/HilbertCurveCompact encode_points {d} {d:.3} {x:0>16}\n", .{ bits, e, harness.checksum(hs) });
    }
    try stdout.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    domains = .{ try create(32), try create(16) };
    try harness.run(init, "adolgert/HilbertCurveCompact", encode, decode);
    var it = init.minimal.args.iterate();
    _ = it.skip();
    try batch(init, try std.fmt.parseInt(usize, it.next() orelse "8388608", 10));
}
