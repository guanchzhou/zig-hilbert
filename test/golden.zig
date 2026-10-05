//! Every marker in `markers.jsonl` must be reproduced bit for bit. The file
//! doubles as conformance data for other implementations of `hk1`.

const std = @import("std");
const hilbert = @import("hilbert");

const Case = struct {
    input_dims: u32,
    dims: u8,
    bits: u8,
    seed: []const u8,
    embedding: []const f32,
    marker: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

test "golden markers" {
    const gpa = std.testing.allocator;
    var lines = std.mem.tokenizeScalar(u8, @embedFile("markers.jsonl"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        const parsed = try std.json.parseFromSlice(Case, gpa, line, .{});
        defer parsed.deinit();
        const c = parsed.value;
        var space = try hilbert.Space.init(gpa, .{
            .input_dims = c.input_dims,
            .dims = c.dims,
            .bits = c.bits,
            .seed = try std.fmt.parseInt(u64, c.seed, 16),
        });
        defer space.deinit();
        if (space.marker(c.embedding)) |m| {
            var text: [hilbert.Marker.max_len]u8 = undefined;
            try std.testing.expectEqualStrings(c.marker.?, m.format(&text));
        } else |err| {
            try std.testing.expectEqualStrings(c.@"error".?, @errorName(err));
        }
    }
    try std.testing.expect(count >= 50);
}
