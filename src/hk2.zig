//! hk2 keys: multi-table angular locality-sensitive hashing (Charikar 2002), next to hk1.
//!
//! Table `t` has `bits` hyperplanes. Bit `j` of table `t` is set when the
//! projection `sum_i s_t(i, j) * e[i]` is positive, where `s_t(i, j)` is -1
//! if bit `j` of `splitmix64(seed_t, i)` is set and +1 otherwise, and
//! `seed_t = splitmix64(seed, t)`. Two vectors at angle `θ` share one table's
//! key with probability close to `(1 - θ/π)^bits`: exactly for Gaussian
//! hyperplanes, and approached by these ±1 hyperplanes as the input dimension
//! grows. `L` independent tables then collide at least once with probability
//! `1 - (1 - (1 - θ/π)^bits)^L`.
//!
//! Multi-probe (Lv et al. 2007): a query also checks the keys obtained by
//! flipping the bits whose projections lie closest to zero, in increasing
//! order of the summed |projection| of the flipped bits.
//!
//! Marker text: `hk2:<tables>:<bits>:<seed as 16 hex digits>:<key 0>.<key 1>...`,
//! each key in `ceil(bits / 4)` hex digits. hk1 markers are not affected.
//!
//! Keys are bit-identical across platforms: projections accumulate in f64 in
//! input order, and nothing else is computed in floating point.

const std = @import("std");
const marker = @import("marker.zig");

pub const max_tables = 1024;
pub const max_bits = 64;

pub const Error = error{ BitsOutOfRange, TablesOutOfRange, ZeroVector, NonFiniteValue, OutputLengthMismatch };
pub const ParseError = error{InvalidMarker};

pub const Space = struct {
    tables: u16,
    bits: u8,
    seed: u64 = marker.default_seed,

    pub fn init(tables: u16, bits: u8, seed: u64) Error!Space {
        if (tables == 0 or tables > max_tables) return error.TablesOutOfRange;
        if (bits == 0 or bits > max_bits) return error.BitsOutOfRange;
        return .{ .tables = tables, .bits = bits, .seed = seed };
    }

    fn mask(s: Space) u64 {
        return if (s.bits == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(s.bits)) - 1;
    }

    /// One key per table into `out` (length `tables`). If `margins` is given
    /// (length `tables * bits`), it receives every projection, for `probes`.
    pub fn keys(s: Space, e: []const f32, out: []u64, margins: ?[]f64) Error!void {
        if (out.len != s.tables) return error.OutputLengthMismatch;
        if (margins) |m| if (m.len != @as(usize, s.tables) * s.bits) return error.OutputLengthMismatch;
        var nonzero = false;
        for (e) |x| {
            if (!std.math.isFinite(x)) return error.NonFiniteValue;
            nonzero = nonzero or x != 0;
        }
        if (!nonzero) return error.ZeroVector;
        var acc: [max_bits]f64 = undefined;
        for (0..s.tables) |t| {
            const seed_t = marker.splitmix64(s.seed, t);
            @memset(acc[0..s.bits], 0);
            for (e, 0..) |x, i| {
                const w = marker.splitmix64(seed_t, i);
                const v: f64 = x;
                for (0..s.bits) |j| acc[j] += if ((w >> @intCast(j)) & 1 == 1) -v else v;
            }
            var key: u64 = 0;
            for (0..s.bits) |j| {
                if (acc[j] > 0) key |= @as(u64, 1) << @intCast(j);
            }
            out[t] = key;
            if (margins) |m| @memcpy(m[t * s.bits ..][0..s.bits], acc[0..s.bits]);
        }
    }

    /// Writes the marker for `keys` into `buf` and returns it.
    pub fn format(s: Space, key_list: []const u64, buf: []u8) error{NoSpaceLeft}![]u8 {
        var w: std.Io.Writer = .fixed(buf);
        const digits = (s.bits + 3) / 4;
        w.print("hk2:{d}:{d}:{x:0>16}:", .{ s.tables, s.bits, s.seed }) catch return error.NoSpaceLeft;
        for (key_list, 0..) |k, i| {
            if (i > 0) w.writeByte('.') catch return error.NoSpaceLeft;
            w.printInt(k, 16, .lower, .{ .width = digits, .fill = '0' }) catch return error.NoSpaceLeft;
        }
        return w.buffered();
    }

    /// Bytes `format` needs.
    pub fn markerLen(s: Space) usize {
        const digits: usize = (s.bits + 3) / 4;
        var n: usize = 4 + 1 + 16 + 1;
        n += std.fmt.count("{d}:{d}", .{ s.tables, s.bits });
        return n + @as(usize, s.tables) * (digits + 1) - 1;
    }
};

/// Parses a marker; the keys go into `out`, which must hold `tables` keys.
pub fn parse(text: []const u8, out: []u64) ParseError!Space {
    var it = std.mem.splitScalar(u8, text, ':');
    if (!std.mem.eql(u8, it.next() orelse "", "hk2")) return error.InvalidMarker;
    const tables = std.fmt.parseInt(u16, it.next() orelse "", 10) catch return error.InvalidMarker;
    const bits = std.fmt.parseInt(u8, it.next() orelse "", 10) catch return error.InvalidMarker;
    const seed_text = it.next() orelse "";
    if (seed_text.len != 16) return error.InvalidMarker;
    const seed = std.fmt.parseInt(u64, seed_text, 16) catch return error.InvalidMarker;
    const s = Space.init(tables, bits, seed) catch return error.InvalidMarker;
    const body = it.next() orelse return error.InvalidMarker;
    if (it.next() != null or out.len != tables) return error.InvalidMarker;
    const digits = (bits + 3) / 4;
    var parts = std.mem.splitScalar(u8, body, '.');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) {
        if (n == tables or p.len != digits) return error.InvalidMarker;
        const k = std.fmt.parseInt(u64, p, 16) catch return error.InvalidMarker;
        if (k & ~s.mask() != 0) return error.InvalidMarker;
        out[n] = k;
    }
    if (n != tables) return error.InvalidMarker;
    return s;
}

/// Query-directed probes of one table (Lv et al. 2007): `out[0]` is `key`,
/// then keys with bits flipped, in increasing order of the summed |margin|
/// of the flipped bits. Returns how many were written (at most `out.len`,
/// at most 2^bits). `margins` are that table's projections.
pub fn probes(margins: []const f64, key: u64, out: []u64) usize {
    const bits = margins.len;
    std.debug.assert(bits > 0 and bits <= max_bits);
    if (out.len == 0) return 0;
    out[0] = key;
    var order: [max_bits]u8 = undefined;
    for (0..bits) |i| order[i] = @intCast(i);
    std.mem.sort(u8, order[0..bits], margins, struct {
        fn f(m: []const f64, a: u8, b: u8) bool {
            const x = @abs(m[a]);
            const y = @abs(m[b]);
            return x < y or (x == y and a < b);
        }
    }.f);
    var z: [max_bits]f64 = undefined;
    for (0..bits) |i| z[i] = @abs(margins[order[i]]);

    // Candidate perturbation sets over sorted positions, as bit masks; a set's
    // largest position drives the shift and expand steps.
    var cand: [2 * 256]u64 = undefined;
    var score: [2 * 256]f64 = undefined;
    var n_cand: usize = 1;
    cand[0] = 1;
    score[0] = z[0];
    var written: usize = 1;
    while (written < out.len and n_cand > 0) {
        var best: usize = 0;
        for (1..n_cand) |c| {
            if (score[c] < score[best] or (score[c] == score[best] and cand[c] < cand[best])) best = c;
        }
        const set = cand[best];
        const s = score[best];
        n_cand -= 1;
        cand[best] = cand[n_cand];
        score[best] = score[n_cand];

        var flipped = key;
        var rest = set;
        while (rest != 0) {
            const p = @ctz(rest);
            flipped ^= @as(u64, 1) << @intCast(order[p]);
            rest &= rest - 1;
        }
        out[written] = flipped;
        written += 1;

        const m: usize = 63 - @clz(set);
        if (m + 1 < bits and n_cand + 2 <= cand.len) {
            const next = @as(u64, 1) << @intCast(m + 1);
            cand[n_cand] = (set & ~(@as(u64, 1) << @intCast(m))) | next;
            score[n_cand] = s - z[m] + z[m + 1];
            n_cand += 1;
            cand[n_cand] = set | next;
            score[n_cand] = s + z[m + 1];
            n_cand += 1;
        }
    }
    return written;
}

test "keys are deterministic, scale-invariant and flip under negation" {
    const s = try Space.init(16, 8, marker.default_seed);
    var e: [64]f32 = undefined;
    for (&e, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i % 7)) - 3.1;
    var a: [16]u64 = undefined;
    var b: [16]u64 = undefined;
    try s.keys(&e, &a, null);
    for (&e) |*x| x.* *= 4;
    try s.keys(&e, &b, null);
    try std.testing.expectEqualSlices(u64, &a, &b);
    for (&e) |*x| x.* = -x.*;
    var m: [16 * 8]f64 = undefined;
    try s.keys(&e, &b, &m);
    for (a, b, 0..) |x, y, t| {
        var exact_zero = false;
        for (m[t * 8 ..][0..8]) |v| exact_zero = exact_zero or v == 0;
        if (!exact_zero) try std.testing.expectEqual(x ^ 0xff, y);
    }
}

test "rejects bad input" {
    const s = try Space.init(2, 4, 1);
    var out: [2]u64 = undefined;
    try std.testing.expectError(error.ZeroVector, s.keys(&.{ 0, 0 }, &out, null));
    try std.testing.expectError(error.NonFiniteValue, s.keys(&.{ 1, std.math.nan(f32) }, &out, null));
    try std.testing.expectError(error.OutputLengthMismatch, s.keys(&.{ 1, 2 }, out[0..1], null));
    try std.testing.expectError(error.BitsOutOfRange, Space.init(1, 65, 1));
    try std.testing.expectError(error.TablesOutOfRange, Space.init(0, 8, 1));
}

test "collision rate follows (1 - θ/π)^bits" {
    // Pairs at a fixed angle in 512 dimensions; the ±1 hyperplanes should collide at the
    // Gaussian rate within sampling error.
    const d = 512;
    var prng = std.Random.DefaultPrng.init(20261007);
    const r = prng.random();
    var u: [d]f32 = undefined;
    var w: [d]f32 = undefined;
    var v: [d]f32 = undefined;
    for (&u) |*x| x.* = r.floatNorm(f32);
    for (&w) |*x| x.* = r.floatNorm(f32);
    var uu: f64 = 0;
    var uw: f64 = 0;
    for (u, w) |a, b| {
        uu += a * a;
        uw += a * b;
    }
    for (&w, u) |*b, a| b.* -= @floatCast(uw / uu * a);
    var nu: f64 = 0;
    var nw: f64 = 0;
    for (u, w) |a, b| {
        nu += a * a;
        nw += b * b;
    }
    inline for (.{ 1, 4 }) |bits| {
        const theta = std.math.pi / 3.0;
        for (&v, u, w) |*x, a, b| x.* = @floatCast(@cos(theta) * a / @sqrt(nu) + @sin(theta) * b / @sqrt(nw));
        const s = try Space.init(max_tables, bits, 77);
        var ku: [max_tables]u64 = undefined;
        var kv: [max_tables]u64 = undefined;
        try s.keys(&u, &ku, null);
        try s.keys(&v, &kv, null);
        var same: usize = 0;
        for (ku, kv) |a, b| same += @intFromBool(a == b);
        const p = std.math.pow(f64, 1 - theta / std.math.pi, bits);
        const n: f64 = max_tables;
        const got = @as(f64, @floatFromInt(same)) / n;
        try std.testing.expect(@abs(got - p) < 4 * @sqrt(p * (1 - p) / n));
    }
}

test "probes start at the key and flip the least certain bits first" {
    const m = [_]f64{ 0.9, -0.1, 0.5, -0.05 };
    var out: [16]u64 = undefined;
    const n = probes(&m, 0b0101, &out);
    try std.testing.expectEqual(@as(usize, 16), n);
    try std.testing.expectEqual(@as(u64, 0b0101), out[0]);
    try std.testing.expectEqual(@as(u64, 0b1101), out[1]); // bit 3, |m| 0.05
    try std.testing.expectEqual(@as(u64, 0b0111), out[2]); // bit 1, 0.1
    try std.testing.expectEqual(@as(u64, 0b1111), out[3]); // bits 3 and 1, 0.15
    for (out[0..n], 0..) |a, i| for (out[0..i]) |b| try std.testing.expect(a != b);
}

test "marker round trip" {
    const s = try Space.init(3, 10, 0x9e3779b97f4a7c15);
    const k = [_]u64{ 0x3ff, 0x0, 0x2a5 };
    var buf: [128]u8 = undefined;
    const text = try s.format(&k, &buf);
    try std.testing.expectEqualStrings("hk2:3:10:9e3779b97f4a7c15:3ff.000.2a5", text);
    try std.testing.expectEqual(s.markerLen(), text.len);
    var back: [3]u64 = undefined;
    const s2 = try parse(text, &back);
    try std.testing.expectEqual(s, s2);
    try std.testing.expectEqualSlices(u64, &k, &back);
    try std.testing.expectError(error.InvalidMarker, parse("hk2:3:10:9e3779b97f4a7c15:3ff.000", &back));
    try std.testing.expectError(error.InvalidMarker, parse("hk2:3:10:9e3779b97f4a7c15:3ff.000.fff", &back));
    try std.testing.expectError(error.InvalidMarker, parse("hk1:3:10:9e3779b97f4a7c15:3ff.000.2a5", &back));
}
