//! `zig-hilbert`: knowledge-marker keys and Hilbert indices from the shell.
//! Every command reads arguments or stdin and writes one result per line,
//! so it composes with scripts and tool-calling models.

const std = @import("std");
const hilbert = @import("hilbert");
const build_options = @import("build_options");

const usage =
    \\usage:
    \\  zig-hilbert key [--dims N] [--bits N] [--seed HEX] [--threads N]
    \\                  [--format text|jsonl] [--max-line BYTES]
    \\                  [--probe LEVEL [--ranges N]]
    \\        stdin: one embedding per line, either a JSON array of numbers or
    \\        an object {"id": ..., "embedding": [...]}
    \\        stdout (text): MARKER, or ID<TAB>MARKER when the line has an id
    \\        stdout (jsonl): {"id":...,"marker":"...","key":"HEX","cell":[...]}
    \\        --probe: instead of the marker, up to N (default 8) "LO HI" marker
    \\        ranges covering the cell at LEVEL and its nearest neighbours
    \\        (jsonl adds "ranges":[["LO","HI"],...])
    \\  zig-hilbert range MARKER LEVEL
    \\        stdout: "LO HI" markers bounding the cell that keeps LEVEL bits per axis
    \\  zig-hilbert similar MARKER MARKER
    \\        stdout: number of leading key bits the two markers share
    \\  zig-hilbert cell MARKER
    \\        stdout: the quantized cell coordinates, one per axis
    \\  zig-hilbert check MARKER
    \\        exit 0 and echo the marker if it is valid, exit 1 otherwise
    \\  zig-hilbert encode2 BITS X Y
    \\  zig-hilbert decode2 BITS INDEX
    \\  zig-hilbert version
    \\
;

const default_max_line = 4 << 20;
/// Embeddings per block: output starts after the first block and memory
/// stays bounded however long stdin is.
const max_block_rows = 4096;
const max_block_values = 4 << 20;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zig-hilbert: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn parseInt(comptime T: type, text: []const u8, what: []const u8) T {
    return std.fmt.parseInt(T, text, 0) catch fail("invalid {s}: {s}", .{ what, text });
}

fn parseMarker(text: []const u8) hilbert.Marker {
    return hilbert.Marker.parse(text) catch fail("invalid marker: {s}", .{text});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    const cmd = args[1];
    const rest = args[2..];

    if (eql(cmd, "key")) {
        try keyCommand(init, rest, out);
    } else if (eql(cmd, "range")) {
        if (rest.len != 2) fail("range takes MARKER LEVEL", .{});
        const r = parseMarker(rest[0]).range(parseInt(u8, rest[1], "level"));
        var a: [hilbert.Marker.max_len]u8 = undefined;
        var b: [hilbert.Marker.max_len]u8 = undefined;
        try out.print("{s} {s}\n", .{ r.lo.format(&a), r.hi.format(&b) });
    } else if (eql(cmd, "similar")) {
        if (rest.len != 2) fail("similar takes MARKER MARKER", .{});
        const bits = hilbert.Marker.sharedPrefixBits(parseMarker(rest[0]), parseMarker(rest[1])) orelse
            fail("markers come from different spaces", .{});
        try out.print("{d}\n", .{bits});
    } else if (eql(cmd, "cell")) {
        if (rest.len != 1) fail("cell takes MARKER", .{});
        const m = parseMarker(rest[0]);
        var c: [hilbert.curvend.max_dims]u32 = undefined;
        hilbert.curvend.decodeChecked(m.dims, m.bits, m.key, c[0..m.dims]) catch unreachable;
        for (c[0..m.dims], 0..) |v, i| try out.print("{s}{d}", .{ if (i == 0) "" else " ", v });
        try out.writeAll("\n");
    } else if (eql(cmd, "check")) {
        if (rest.len != 1) fail("check takes MARKER", .{});
        var a: [hilbert.Marker.max_len]u8 = undefined;
        try out.print("{s}\n", .{parseMarker(rest[0]).format(&a)});
    } else if (eql(cmd, "encode2")) {
        if (rest.len != 3) fail("encode2 takes BITS X Y", .{});
        const h = hilbert.encode2Checked(parseInt(u6, rest[0], "bits"), parseInt(u32, rest[1], "x"), parseInt(u32, rest[2], "y")) catch |e|
            fail("{s}", .{@errorName(e)});
        try out.print("{d}\n", .{h});
    } else if (eql(cmd, "decode2")) {
        if (rest.len != 2) fail("decode2 takes BITS INDEX", .{});
        const p = hilbert.decode2Checked(parseInt(u6, rest[0], "bits"), parseInt(u64, rest[1], "index")) catch |e|
            fail("{s}", .{@errorName(e)});
        try out.print("{d} {d}\n", .{ p.x, p.y });
    } else if (eql(cmd, "version") or eql(cmd, "--version")) {
        try out.print("zig-hilbert {s}\n", .{build_options.version});
    } else if (eql(cmd, "help") or eql(cmd, "--help") or eql(cmd, "-h")) {
        try out.writeAll(usage);
    } else {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    try out.flush();
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Format = enum { text, jsonl };

const Options = struct {
    dims: u8 = hilbert.marker.default_dims,
    bits: u8 = hilbert.marker.default_bits,
    seed: u64 = hilbert.marker.default_seed,
    threads: usize = 0,
    format: Format = .text,
    max_line: usize = default_max_line,
    probe: ?u8 = null,
    ranges: usize = 8,
};

const max_ranges = 64;

fn parseOptions(args: []const [:0]const u8) Options {
    var o: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const name = args[i];
        if (i + 1 >= args.len) fail("missing value for {s}", .{name});
        const v = args[i + 1];
        if (eql(name, "--dims")) {
            o.dims = parseInt(u8, v, "dims");
        } else if (eql(name, "--bits")) {
            o.bits = parseInt(u8, v, "bits");
        } else if (eql(name, "--seed")) {
            const hex = if (std.ascii.startsWithIgnoreCase(v, "0x")) v[2..] else v;
            o.seed = std.fmt.parseInt(u64, hex, 16) catch fail("invalid seed: {s}", .{v});
        } else if (eql(name, "--threads")) {
            o.threads = parseInt(usize, v, "threads");
        } else if (eql(name, "--format")) {
            o.format = std.meta.stringToEnum(Format, v) orelse fail("invalid format: {s}", .{v});
        } else if (eql(name, "--max-line")) {
            o.max_line = @max(parseInt(usize, v, "max-line"), 16);
        } else if (eql(name, "--probe")) {
            o.probe = parseInt(u8, v, "probe level");
        } else if (eql(name, "--ranges")) {
            o.ranges = std.math.clamp(parseInt(usize, v, "ranges"), 1, max_ranges);
        } else fail("unknown option: {s}", .{name});
    }
    return o;
}

const Row = struct { id: ?std.json.Value = null, embedding: []f32 };

const Block = struct {
    values: std.ArrayList(f32) = .empty,
    lines: std.ArrayList(usize) = .empty,
    /// JSON text of each row's id, or empty when the row has none.
    ids: std.ArrayList([]const u8) = .empty,
    id_arena: std.heap.ArenaAllocator,
    keys: std.ArrayList(u128) = .empty,

    fn rows(self: *const Block) usize {
        return self.lines.items.len;
    }

    fn clear(self: *Block) void {
        self.values.clearRetainingCapacity();
        self.lines.clearRetainingCapacity();
        self.ids.clearRetainingCapacity();
        _ = self.id_arena.reset(.retain_capacity);
    }
};

fn keyCommand(init: std.process.Init, args: []const [:0]const u8, out: *std.Io.Writer) !void {
    const gpa = init.gpa;
    const o = parseOptions(args);
    const in_buf = try gpa.alloc(u8, o.max_line);
    defer gpa.free(in_buf);
    var stdin = std.Io.File.stdin().readerStreaming(init.io, in_buf);

    var block: Block = .{ .id_arena = .init(gpa) };
    defer {
        block.values.deinit(gpa);
        block.lines.deinit(gpa);
        block.ids.deinit(gpa);
        block.keys.deinit(gpa);
        block.id_arena.deinit();
    }
    var space: ?hilbert.Space = null;
    defer if (space) |*s| s.deinit();
    var width: usize = 0;
    var block_rows: usize = max_block_rows;
    var total: usize = 0;
    var line_no: usize = 0;

    while (true) {
        const raw = stdin.interface.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => fail("line {d}: longer than {d} bytes (see --max-line)", .{ line_no + 1, o.max_line }),
            error.ReadFailed => return stdin.err.?,
        } orelse break;
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        const parsed = parseRow(gpa, line) catch
            fail("line {d}: expected a JSON array of numbers or an object with \"embedding\"", .{line_no});
        defer parsed.deinit();
        const row = parsed.value;
        if (space == null) {
            width = row.embedding.len;
            if (width == 0) fail("line {d}: empty embedding", .{line_no});
            space = hilbert.Space.init(gpa, .{ .input_dims = std.math.cast(u32, width) orelse std.math.maxInt(u32), .dims = o.dims, .bits = o.bits, .seed = o.seed }) catch |e| switch (e) {
                error.DimensionMismatch => fail("line {d}: {d} numbers, more than the limit of {d}", .{ line_no, width, hilbert.marker.max_input_dims }),
                else => fail("{s}", .{@errorName(e)}),
            };
            block_rows = std.math.clamp(max_block_values / width, 1, max_block_rows);
        }
        if (row.embedding.len != width) fail("line {d}: expected {d} numbers, got {d}", .{ line_no, width, row.embedding.len });
        try block.values.appendSlice(gpa, row.embedding);
        try block.lines.append(gpa, line_no);
        try block.ids.append(gpa, try idText(block.id_arena.allocator(), row.id, o.format, line_no));
        if (block.rows() == block_rows) {
            total += try flush(gpa, &block, &space.?, o, out);
        }
    }
    if (block.rows() > 0) total += try flush(gpa, &block, &space.?, o, out);
    if (total == 0) fail("no embeddings on stdin", .{});
}

fn parseRow(gpa: std.mem.Allocator, line: []const u8) !std.json.Parsed(Row) {
    if (line[0] == '[') {
        const arr = try std.json.parseFromSlice([]f32, gpa, line, .{});
        return .{ .arena = arr.arena, .value = .{ .embedding = arr.value } };
    }
    return std.json.parseFromSlice(Row, gpa, line, .{ .ignore_unknown_fields = true });
}

/// The id as it will be printed: raw text for `text` output (which must
/// not contain a tab or line break), JSON for `jsonl`.
fn idText(arena: std.mem.Allocator, id: ?std.json.Value, format: Format, line_no: usize) ![]const u8 {
    const v = id orelse return "";
    switch (format) {
        .jsonl => return std.json.Stringify.valueAlloc(arena, v, .{}),
        .text => {
            const text = switch (v) {
                .string, .number_string => |s| s,
                .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
                else => fail("line {d}: id must be a string or a number", .{line_no}),
            };
            if (std.mem.indexOfAny(u8, text, "\t\r\n") != null) fail("line {d}: id contains a tab or line break; use --format jsonl", .{line_no});
            return arena.dupe(u8, text);
        },
    }
}

fn flush(gpa: std.mem.Allocator, block: *Block, space: *const hilbert.Space, o: Options, out: *std.Io.Writer) !usize {
    const n = block.rows();
    try block.keys.resize(gpa, n);
    var failed: usize = 0;
    space.keys(block.values.items, block.keys.items, o.threads, &failed) catch |e|
        fail("line {d}: {s}", .{ block.lines.items[failed], @errorName(e) });
    var text: [hilbert.Marker.max_len]u8 = undefined;
    var lo_text: [hilbert.Marker.max_len]u8 = undefined;
    var range_buf: [max_ranges]hilbert.marker.KeyRange = undefined;
    for (block.keys.items, block.ids.items, 0..) |k, id, row| {
        const m: hilbert.Marker = .{ .dims = o.dims, .bits = o.bits, .seed = o.seed, .key = k };
        const marker = m.format(&text);
        const ranges = if (o.probe) |level|
            space.probes(block.values.items[row * space.input_dims ..][0..space.input_dims], level, range_buf[0..o.ranges]) catch unreachable
        else
            &.{};
        switch (o.format) {
            .text => {
                if (id.len > 0) try out.print("{s}\t", .{id});
                if (o.probe == null) {
                    try out.print("{s}\n", .{marker});
                } else {
                    for (ranges, 0..) |r, i| {
                        var lo = m;
                        var hi = m;
                        lo.key = r.lo;
                        hi.key = r.hi;
                        try out.print("{s}{s} {s}", .{ if (i == 0) "" else " ", lo.format(&lo_text), hi.format(&text) });
                    }
                    try out.writeAll("\n");
                }
            },
            .jsonl => {
                try out.writeAll("{");
                if (id.len > 0) try out.print("\"id\":{s},", .{id});
                const key_hex = marker[std.mem.lastIndexOfScalar(u8, marker, ':').? + 1 ..];
                try out.print("\"marker\":\"{s}\",\"key\":\"{s}\",\"cell\":[", .{ marker, key_hex });
                var c: [hilbert.curvend.max_dims]u32 = undefined;
                hilbert.curvend.decodeChecked(o.dims, o.bits, k, c[0..o.dims]) catch unreachable;
                for (c[0..o.dims], 0..) |v, i| try out.print("{s}{d}", .{ if (i == 0) "" else ",", v });
                try out.writeAll("]");
                if (o.probe != null) {
                    try out.writeAll(",\"ranges\":[");
                    for (ranges, 0..) |r, i| {
                        var lo = m;
                        var hi = m;
                        lo.key = r.lo;
                        hi.key = r.hi;
                        try out.print("{s}[\"{s}\",\"{s}\"]", .{ if (i == 0) "" else ",", lo.format(&lo_text), hi.format(&text) });
                    }
                    try out.writeAll("]");
                }
                try out.writeAll("}\n");
            },
        }
    }
    try out.flush();
    block.clear();
    return n;
}
