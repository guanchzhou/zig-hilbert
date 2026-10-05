//! `zig-hilbert`: knowledge-marker keys and Hilbert indices from the shell.
//! Every command reads arguments or stdin and writes one result per line,
//! so it composes with scripts and tool-calling models.

const std = @import("std");
const hilbert = @import("hilbert");

const usage =
    \\usage:
    \\  zig-hilbert key   [--dims N] [--bits N] [--seed HEX] [--threads N]
    \\        stdin: one JSON array of numbers per line; stdout: one marker per line
    \\  zig-hilbert range MARKER LEVEL
    \\        stdout: "LO HI" markers bounding the cell that keeps LEVEL bits per axis
    \\  zig-hilbert check MARKER
    \\        exit 0 and echo the marker if it is valid, exit 1 otherwise
    \\  zig-hilbert encode2 BITS X Y
    \\  zig-hilbert decode2 BITS INDEX
    \\
;

const max_input = 256 << 20;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zig-hilbert: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn parseInt(comptime T: type, text: []const u8, what: []const u8) T {
    return std.fmt.parseInt(T, text, 0) catch fail("invalid {s}: {s}", .{ what, text });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    var buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const out = &stdout.interface;
    const cmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "key")) {
        try keyCommand(init, gpa, rest, out);
    } else if (std.mem.eql(u8, cmd, "range")) {
        if (rest.len != 2) fail("range takes MARKER LEVEL", .{});
        const m = hilbert.Marker.parse(rest[0]) catch fail("invalid marker: {s}", .{rest[0]});
        const r = m.range(parseInt(u8, rest[1], "level"));
        var a: [hilbert.Marker.max_len]u8 = undefined;
        var b: [hilbert.Marker.max_len]u8 = undefined;
        try out.print("{s} {s}\n", .{ r.lo.format(&a), r.hi.format(&b) });
    } else if (std.mem.eql(u8, cmd, "check")) {
        if (rest.len != 1) fail("check takes MARKER", .{});
        const m = hilbert.Marker.parse(rest[0]) catch fail("invalid marker: {s}", .{rest[0]});
        var a: [hilbert.Marker.max_len]u8 = undefined;
        try out.print("{s}\n", .{m.format(&a)});
    } else if (std.mem.eql(u8, cmd, "encode2")) {
        if (rest.len != 3) fail("encode2 takes BITS X Y", .{});
        const h = hilbert.encode2Checked(parseInt(u6, rest[0], "bits"), parseInt(u32, rest[1], "x"), parseInt(u32, rest[2], "y")) catch |e|
            fail("{s}", .{@errorName(e)});
        try out.print("{d}\n", .{h});
    } else if (std.mem.eql(u8, cmd, "decode2")) {
        if (rest.len != 2) fail("decode2 takes BITS INDEX", .{});
        const p = hilbert.decode2Checked(parseInt(u6, rest[0], "bits"), parseInt(u64, rest[1], "index")) catch |e|
            fail("{s}", .{@errorName(e)});
        try out.print("{d} {d}\n", .{ p.x, p.y });
    } else {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    try out.flush();
}

fn keyCommand(init: std.process.Init, gpa: std.mem.Allocator, args: []const [:0]const u8, out: *std.Io.Writer) !void {
    var dims: u8 = hilbert.marker.default_dims;
    var bits: u8 = hilbert.marker.default_bits;
    var seed: u64 = hilbert.marker.default_seed;
    var threads: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) fail("missing value for {s}", .{args[i]});
        const v = args[i + 1];
        if (std.mem.eql(u8, args[i], "--dims")) dims = parseInt(u8, v, "dims") else if (std.mem.eql(u8, args[i], "--bits")) bits = parseInt(u8, v, "bits") else if (std.mem.eql(u8, args[i], "--seed")) seed = std.fmt.parseInt(u64, v, 16) catch fail("invalid seed: {s}", .{v}) else if (std.mem.eql(u8, args[i], "--threads")) threads = parseInt(usize, v, "threads") else fail("unknown option: {s}", .{args[i]});
    }

    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    const input = stdin.interface.allocRemaining(gpa, .limited(max_input)) catch |e| switch (e) {
        error.StreamTooLong => fail("input larger than {d} bytes", .{max_input}),
        else => return e,
    };
    defer gpa.free(input);

    var values: std.ArrayList(f32) = .empty;
    defer values.deinit(gpa);
    var width: usize = 0;
    var rows: usize = 0;
    var lines = std.mem.tokenizeAny(u8, input, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice([]f32, gpa, trimmed, .{}) catch
            fail("line {d}: expected a JSON array of numbers", .{rows + 1});
        defer parsed.deinit();
        if (rows == 0) width = parsed.value.len;
        if (parsed.value.len != width or width == 0) fail("line {d}: expected {d} numbers, got {d}", .{ rows + 1, width, parsed.value.len });
        try values.appendSlice(gpa, parsed.value);
        rows += 1;
    }
    if (rows == 0) fail("no embeddings on stdin", .{});

    var space = hilbert.Space.init(gpa, .{ .input_dims = @intCast(width), .dims = dims, .bits = bits, .seed = seed }) catch |e|
        fail("{s}", .{@errorName(e)});
    defer space.deinit();
    const keys = try gpa.alloc(u128, rows);
    defer gpa.free(keys);
    space.keys(values.items, keys, threads) catch |e| fail("{s}", .{@errorName(e)});
    var text: [hilbert.Marker.max_len]u8 = undefined;
    for (keys) |k| {
        const m: hilbert.Marker = .{ .dims = dims, .bits = bits, .seed = seed, .key = k };
        try out.print("{s}\n", .{m.format(&text)});
    }
}
