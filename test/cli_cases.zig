//! Command-line cases run by `zig build test-cli`. `stdout` is compared
//! exactly, `stderr` as a substring.

pub const Case = struct {
    name: []const u8,
    args: []const []const u8,
    stdin: ?[]const u8 = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    exit: u8 = 0,
};

const m = "hk1:8:8:9e3779b97f4a7c15:a0c28ad75ed48ca8";

pub const cases = [_]Case{
    .{
        .name = "key: default space",
        .args = &.{"key"},
        .stdin = "[1,2,3]\n[3,2,1]\n",
        .stdout = "hk1:8:8:9e3779b97f4a7c15:8f0ba155fbabafff\nhk1:8:8:9e3779b97f4a7c15:90fc5eaef82c2a04\n",
    },
    .{
        .name = "key: CRLF, blank lines, and spaces",
        .args = &.{ "key", "--dims", "2", "--bits", "4" },
        .stdin = "[1,2,3]\r\n\r\n  [0.5, -1, 2e-3]  \r\n",
        .stdout = "hk1:2:4:9e3779b97f4a7c15:8a\nhk1:2:4:9e3779b97f4a7c15:a8\n",
    },
    .{
        .name = "key: seed and threads",
        .args = &.{ "key", "--dims", "3", "--bits", "10", "--seed", "1", "--threads", "1" },
        .stdin = "[1,2,3]\n",
        .stdout = "hk1:3:10:0000000000000001:3c912894\n",
    },
    .{
        .name = "key: ids in text output",
        .args = &.{"key"},
        .stdin = "{\"id\":\"note-1\",\"embedding\":[1,2,3],\"extra\":true}\n{\"id\":42,\"embedding\":[3,2,1]}\n[1,2,3]\n",
        .stdout = "note-1\thk1:8:8:9e3779b97f4a7c15:8f0ba155fbabafff\n42\thk1:8:8:9e3779b97f4a7c15:90fc5eaef82c2a04\nhk1:8:8:9e3779b97f4a7c15:8f0ba155fbabafff\n",
    },
    .{
        .name = "key: jsonl output",
        .args = &.{ "key", "--format", "jsonl", "--dims", "2", "--bits", "4" },
        .stdin = "{\"id\":\"a\\tb\",\"embedding\":[1,2,3]}\n[0.5,-1,2e-3]\n",
        .stdout = "{\"id\":\"a\\tb\",\"marker\":\"hk1:2:4:9e3779b97f4a7c15:8a\",\"key\":\"8a\",\"cell\":[11,11]}\n{\"marker\":\"hk1:2:4:9e3779b97f4a7c15:a8\",\"key\":\"a8\",\"cell\":[14,14]}\n",
    },
    .{
        .name = "key: probe ranges",
        .args = &.{ "key", "--probe", "2", "--ranges", "4" },
        .stdin = "[1,2,3]\n",
        .stdout = "hk1:8:8:9e3779b97f4a7c15:8f08000000000000 hk1:8:8:9e3779b97f4a7c15:8f08ffffffffffff hk1:8:8:9e3779b97f4a7c15:8f0b000000000000 hk1:8:8:9e3779b97f4a7c15:8f0bffffffffffff hk1:8:8:9e3779b97f4a7c15:8ff4000000000000 hk1:8:8:9e3779b97f4a7c15:8ff4ffffffffffff hk1:8:8:9e3779b97f4a7c15:8ff7000000000000 hk1:8:8:9e3779b97f4a7c15:8ff7ffffffffffff\n",
    },
    .{
        .name = "key: probe ranges in jsonl",
        .args = &.{ "key", "--probe", "1", "--ranges", "2", "--format", "jsonl" },
        .stdin = "{\"id\":\"n\",\"embedding\":[1,2,3]}\n",
        .stdout = "{\"id\":\"n\",\"marker\":\"hk1:8:8:9e3779b97f4a7c15:8f0ba155fbabafff\",\"key\":\"8f0ba155fbabafff\",\"cell\":[182,182,15,35,220,73,15,73],\"ranges\":[[\"hk1:8:8:9e3779b97f4a7c15:7000000000000000\",\"hk1:8:8:9e3779b97f4a7c15:70ffffffffffffff\"],[\"hk1:8:8:9e3779b97f4a7c15:8f00000000000000\",\"hk1:8:8:9e3779b97f4a7c15:8fffffffffffffff\"]]}\n",
    },
    .{ .name = "key: seed with 0x prefix", .args = &.{ "key", "--dims", "3", "--bits", "10", "--seed", "0x1" }, .stdin = "[1,2,3]\n", .stdout = "hk1:3:10:0000000000000001:3c912894\n" },
    .{ .name = "key: tab in a text id", .args = &.{"key"}, .stdin = "{\"id\":\"a\\tb\",\"embedding\":[1,2,3]}\n", .stderr = "line 1: id contains a tab or line break", .exit = 1 },
    .{ .name = "key: object id", .args = &.{"key"}, .stdin = "{\"id\":{},\"embedding\":[1,2,3]}\n", .stderr = "line 1: id must be a string or a number", .exit = 1 },
    .{ .name = "key: ragged rows", .args = &.{"key"}, .stdin = "[1,2,3]\n[1,2]\n", .stderr = "line 2: expected 3 numbers, got 2", .exit = 1 },
    .{ .name = "key: overflowing number reports its line", .args = &.{"key"}, .stdin = "[1,2,3]\n\n[3,2,1]\n[1e400,1,1]\n", .stderr = "line 4: NonFiniteValue", .exit = 1 },
    .{ .name = "key: not numbers", .args = &.{"key"}, .stdin = "[\"a\"]\n", .stderr = "line 1: expected a JSON array of numbers", .exit = 1 },
    .{ .name = "key: object without embedding", .args = &.{"key"}, .stdin = "{\"x\":1}\n", .stderr = "line 1: expected a JSON array of numbers or an object", .exit = 1 },
    .{ .name = "key: empty embedding", .args = &.{"key"}, .stdin = "[]\n", .stderr = "line 1: empty embedding", .exit = 1 },
    .{ .name = "key: empty input", .args = &.{"key"}, .stdin = "", .stderr = "no embeddings on stdin", .exit = 1 },
    .{ .name = "key: zero vector", .args = &.{"key"}, .stdin = "[1,1,1]\n[0,0,0]\n", .stderr = "line 2: ZeroVector", .exit = 1 },
    .{ .name = "key: line too long", .args = &.{ "key", "--max-line", "16" }, .stdin = "[1,2,3,4,5,6,7,8,9,10]\n", .stderr = "line 1: longer than 16 bytes", .exit = 1 },
    .{ .name = "key: bad space", .args = &.{ "key", "--dims", "16", "--bits", "9" }, .stdin = "[1]\n", .stderr = "OrderOutOfRange", .exit = 1 },
    .{ .name = "key: bad format", .args = &.{ "key", "--format", "xml" }, .stderr = "invalid format: xml", .exit = 1 },
    .{ .name = "key: unknown option", .args = &.{ "key", "--nope", "1" }, .stderr = "unknown option: --nope", .exit = 1 },
    .{ .name = "key: missing value", .args = &.{ "key", "--dims" }, .stderr = "missing value for --dims", .exit = 1 },
    .{ .name = "key: bad seed", .args = &.{ "key", "--seed", "xyz" }, .stderr = "invalid seed: xyz", .exit = 1 },

    .{ .name = "similar", .args = &.{ "similar", m, "hk1:8:8:9e3779b97f4a7c15:a0c28ad5a7be0843" }, .stdout = "30\n" },
    .{ .name = "similar: same marker", .args = &.{ "similar", m, m }, .stdout = "64\n" },
    .{ .name = "similar: different spaces", .args = &.{ "similar", m, "hk1:8:8:0000000000000001:a0c28ad75ed48ca8" }, .stderr = "different spaces", .exit = 1 },
    .{ .name = "cell", .args = &.{ "cell", "hk1:2:4:9e3779b97f4a7c15:8a" }, .stdout = "11 11\n" },
    .{ .name = "version", .args = &.{"version"}, .stdout = "zig-hilbert " ++ @import("../build.zig.zon").version ++ "\n" },
    .{ .name = "help", .args = &.{"--help"}, .stdout = null },

    .{ .name = "range: level 3", .args = &.{ "range", m, "3" }, .stdout = "hk1:8:8:9e3779b97f4a7c15:a0c28a0000000000 hk1:8:8:9e3779b97f4a7c15:a0c28affffffffff\n" },
    .{ .name = "range: level 0 is the whole space", .args = &.{ "range", m, "0" }, .stdout = "hk1:8:8:9e3779b97f4a7c15:0000000000000000 hk1:8:8:9e3779b97f4a7c15:ffffffffffffffff\n" },
    .{ .name = "range: level above bits is the key", .args = &.{ "range", m, "99" }, .stdout = m ++ " " ++ m ++ "\n" },
    .{ .name = "range: bad marker", .args = &.{ "range", "hk1:8:8:x:y", "3" }, .stderr = "invalid marker", .exit = 1 },
    .{ .name = "range: bad level", .args = &.{ "range", m, "-1" }, .stderr = "invalid level", .exit = 1 },

    .{ .name = "check: valid", .args = &.{ "check", m }, .stdout = m ++ "\n" },
    .{ .name = "check: uppercase rejected", .args = &.{ "check", "hk1:8:8:9E3779B97F4A7C15:a0c28ad75ed48ca8" }, .stderr = "invalid marker", .exit = 1 },
    .{ .name = "check: short key rejected", .args = &.{ "check", "hk1:8:8:9e3779b97f4a7c15:a0c2" }, .stderr = "invalid marker", .exit = 1 },

    .{ .name = "encode2", .args = &.{ "encode2", "16", "12345", "54321" }, .stdout = "1555040834\n" },
    .{ .name = "decode2", .args = &.{ "decode2", "16", "1555040834" }, .stdout = "12345 54321\n" },
    .{ .name = "encode2: coordinate out of range", .args = &.{ "encode2", "4", "16", "0" }, .stderr = "CoordinateOutOfRange", .exit = 1 },
    .{ .name = "decode2: order out of range", .args = &.{ "decode2", "33", "0" }, .stderr = "OrderOutOfRange", .exit = 1 },
    .{ .name = "decode2: index out of range", .args = &.{ "decode2", "4", "256" }, .stderr = "IndexOutOfRange", .exit = 1 },
    .{ .name = "encode2: not a number", .args = &.{ "encode2", "16", "x", "1" }, .stderr = "invalid x: x", .exit = 1 },

    .{ .name = "s2-token", .args = &.{ "s2-token", "37.4", "-122.1" }, .stdout = "808fb0bb44a3d46b\n" },
    .{ .name = "s2-token: level", .args = &.{ "s2-token", "37.4", "-122.1", "12" }, .stdout = "808fb0b\n" },
    .{ .name = "s2-token: latitude", .args = &.{ "s2-token", "91", "0" }, .stderr = "LatitudeOutOfRange", .exit = 1 },
    .{ .name = "s2-token: level above the leaf", .args = &.{ "s2-token", "0", "0", "31" }, .stderr = "LevelOutOfRange", .exit = 1 },
    .{
        .name = "s2-cover",
        .args = &.{ "s2-cover", "37.4", "-122.1", "1000", "--max-level", "12", "--max-cells", "8" },
        .stdout =
        \\9263817022326702081 9263817159765655551
        \\9263817159765655553 9263817297204609023
        \\9263817297204609025 9263817434643562495
        \\9263824306591236097 9263824444030189567
        \\9263824444030189569 9263824581469143039
        \\9263827467687165953 9263827605126119423
        \\9263827880004026369 9263828017442979839
        \\
        ,
    },
    .{
        .name = "s2-polyline",
        .args = &.{ "s2-polyline", "--max-level", "12", "--max-cells", "8" },
        .stdin = "10 10\n10.2 10.3\n",
        .stdout =
        \\1176871066883063809 1176873265906319359
        \\1176874777734807553 1176874915173761023
        \\1176874915173761025 1176875464929574911
        \\1176877114197016577 1176877663952830463
        \\1176914909909221377 1176915047348174847
        \\1176915047348174849 1176917246371430399
        \\1176917933566197761 1176918071005151231
        \\1176924942952824833 1176925492708638719
        \\
        ,
    },
    .{
        .name = "s2-polygon",
        .args = &.{ "s2-polygon", "--max-level", "12", "--max-cells", "16" },
        .stdin = "20 20\n20 20.2\n20.2 20.1\n",
        .stdout =
        \\1249508240987783169 1249508378426736639
        \\1249508378426736641 1249508515865690111
        \\1249517999153479681 1249518548909293567
        \\1249518548909293569 1249519098665107455
        \\1249519648420921345 1249520198176735231
        \\1249520198176735233 1249520747932549119
        \\1249520747932549121 1249521297688363007
        \\1249521297688363009 1249521847444176895
        \\1249521847444176897 1249522397199990783
        \\1249522397199990785 1249522946955804671
        \\1249524046467432449 1249524596223246335
        \\1249524596223246337 1249525145979060223
        \\1249527345002315777 1249527894758129663
        \\1249527894758129665 1249528444513943551
        \\1249531193293012993 1249533392316268543
        \\1249533942072082433 1249534079511035903
        \\
        ,
    },
    .{ .name = "s2-polygon: too few vertices", .args = &.{"s2-polygon"}, .stdin = "1 2\n3 4\n", .stderr = "RegionOutOfRange", .exit = 1 },
    .{ .name = "s2-polyline: empty", .args = &.{"s2-polyline"}, .stdin = "", .stderr = "no points on stdin", .exit = 1 },
    .{ .name = "s2-cover: bad radius", .args = &.{ "s2-cover", "0", "0", "-1" }, .stderr = "RadiusOutOfRange", .exit = 1 },

    .{ .name = "no arguments", .args = &.{}, .stderr = "usage:", .exit = 2 },
    .{ .name = "unknown command", .args = &.{"frobnicate"}, .stderr = "usage:", .exit = 2 },
};
