//! Cell ids compatible with Google's S2 library.
//!
//! A cell id is a u64: 3 bits of cube face, then the position of the cell
//! along the Hilbert curve on that face, with a trailing 1-bit marking the
//! level. `curve2d.Tables` supplies that curve (the same orientation S2
//! uses, swapped on odd faces). Latitude and longitude go through S2's
//! quadratic face projection, so the ids match S2 bit for bit.

const std = @import("std");
const curve2d = @import("curve2d.zig");

pub const max_level: u8 = 30;
/// Mean Earth radius used by S2, in metres.
pub const earth_radius_m: f64 = 6371010.0;

pub const Error = error{
    LevelOutOfRange,
    InvalidCell,
    LatitudeOutOfRange,
    NonFinite,
    RadiusOutOfRange,
    BufferTooSmall,
};

pub const LatLng = struct { lat: f64, lng: f64 };

/// Inclusive id interval covering a cell and every cell inside it.
pub const Range = struct { lo: u64, hi: u64 };

const max_size: i32 = 1 << max_level;

pub const Cell = struct {
    id: u64,

    pub fn face(self: Cell) u3 {
        return @intCast(self.id >> 61);
    }

    pub fn pos(self: Cell) u64 {
        return self.id & (~@as(u64, 0) >> 3);
    }

    pub fn level(self: Cell) u8 {
        if (self.id == 0) return 0;
        return max_level - @as(u8, @intCast(@ctz(self.id) >> 1));
    }

    pub fn valid(self: Cell) bool {
        return self.id >> 61 < 6 and (lsb(self.id) & 0x1555555555555555) != 0;
    }

    pub fn leaf(self: Cell) bool {
        return self.id & 1 == 1;
    }

    /// `level` must be at most `self.level()`.
    pub fn parent(self: Cell, level_: u8) Cell {
        const new_lsb = lsbForLevel(level_);
        return .{ .id = (self.id & ~(new_lsb - 1)) | new_lsb };
    }

    /// The child at `position` (0..3). `self` must not be a leaf.
    pub fn child(self: Cell, position: u2) Cell {
        const new_lsb: i64 = @intCast(lsb(self.id) >> 2);
        const delta = (@as(i64, 2) * position + 1 - 4) * new_lsb;
        return .{ .id = @bitCast(@as(i64, @bitCast(self.id)) + delta) };
    }

    pub fn children(self: Cell) [4]Cell {
        return .{ self.child(0), self.child(1), self.child(2), self.child(3) };
    }

    pub fn range(self: Cell) Range {
        const bit = lsb(self.id);
        return .{ .lo = self.id - (bit - 1), .hi = self.id + (bit - 1) };
    }

    pub fn contains(self: Cell, other: Cell) bool {
        const r = self.range();
        return other.id >= r.lo and other.id <= r.hi;
    }

    /// Four edge-adjacent cells at the same level, in the order down, right,
    /// up, left. A cube corner can repeat a neighbour.
    pub fn edgeNeighbors(self: Cell) [4]Cell {
        const level_ = self.level();
        const size = sizeIJ(level_);
        var i: i32 = undefined;
        var j: i32 = undefined;
        const f = toFaceIJ(self, &i, &j);
        return .{
            cellAt(f, i, j - size, level_),
            cellAt(f, i + size, j, level_),
            cellAt(f, i, j + size, level_),
            cellAt(f, i - size, j, level_),
        };
    }

    /// Hex token, matching `S2CellId::ToToken`. `id == 0` is `"X"`.
    pub fn token(self: Cell, buf: *[16]u8) []const u8 {
        if (self.id == 0) {
            buf[0] = 'X';
            return buf[0..1];
        }
        const zeros = @ctz(self.id) / 4;
        const digits: usize = 16 - zeros;
        var v = self.id >> @intCast(4 * zeros);
        var k = digits;
        while (k > 0) {
            k -= 1;
            buf[k] = "0123456789abcdef"[@as(u4, @truncate(v))];
            v >>= 4;
        }
        return buf[0..digits];
    }

    pub fn center(self: Cell) LatLng {
        var i: i32 = undefined;
        var j: i32 = undefined;
        const f = toFaceIJ(self, &i, &j);
        const low: i32 = @intCast((self.id >> 2) & 1);
        const delta: i32 = if (self.leaf()) 1 else if (((i ^ low) & 1) == 1) 2 else 0;
        const u = stToUv(siTiToSt(@intCast(2 * i + delta)));
        const v = stToUv(siTiToSt(@intCast(2 * j + delta)));
        const p = faceUvToXyz(f, u, v);
        return .{
            .lat = std.math.atan2(p.z, @sqrt(p.x * p.x + p.y * p.y)) * (180.0 / std.math.pi),
            .lng = std.math.atan2(p.y, p.x) * (180.0 / std.math.pi),
        };
    }

    /// Leaf cell for `(i, j)` on `face`. Precondition: both coordinates are
    /// `< 2^30`.
    pub fn fromFaceIJ(face_: u3, i: u32, j: u32) Cell {
        const hilbert = hilbertPos(face_, i, j);
        return .{ .id = (@as(u64, face_) << 61) | (hilbert << 1) | 1 };
    }

    pub fn fromFace(face_: u3) Cell {
        return .{ .id = (@as(u64, face_) << 61) + lsbForLevel(0) };
    }

    /// Snaps `pos` to the center of the cell at `level` that contains it.
    pub fn fromFacePosLevel(face_: u3, pos_: u64, level_: u8) Error!Cell {
        if (level_ > max_level) return error.LevelOutOfRange;
        const cell: Cell = .{ .id = (@as(u64, face_) << 61) + (pos_ | 1) };
        return cell.parent(level_);
    }
};

/// Leaf cell containing the point. Latitude must be in [-90, 90].
pub fn fromLatLng(lat: f64, lng: f64) Error!Cell {
    if (!std.math.isFinite(lat) or !std.math.isFinite(lng)) return error.NonFinite;
    if (lat < -90 or lat > 90) return error.LatitudeOutOfRange;
    const phi = lat * (std.math.pi / 180.0);
    const theta = lng * (std.math.pi / 180.0);
    const cos_phi = @cos(phi);
    var u: f64 = undefined;
    var v: f64 = undefined;
    const face_ = xyzToFaceUv(cos_phi * @cos(theta), cos_phi * @sin(theta), @sin(phi), &u, &v);
    return Cell.fromFaceIJ(face_, stToIJ(uvToSt(u)), stToIJ(uvToSt(v)));
}

/// `fromLatLng` raised to `level`.
pub fn atLevel(lat: f64, lng: f64, level_: u8) Error!Cell {
    if (level_ > max_level) return error.LevelOutOfRange;
    return (try fromLatLng(lat, lng)).parent(level_);
}

/// Parse a token from `Cell.token`. `"X"` is cell id 0.
pub fn fromToken(text: []const u8) Error!Cell {
    if (std.mem.eql(u8, text, "X")) return .{ .id = 0 };
    if (text.len == 0 or text.len > 16) return error.InvalidCell;
    var id: u64 = 0;
    for (text) |c| {
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidCell,
        };
        id = (id << 4) | d;
    }
    id <<= @intCast(4 * (16 - text.len));
    const cell: Cell = .{ .id = id };
    if (!cell.valid()) return error.InvalidCell;
    return cell;
}

/// Merged id ranges whose cells cover the cap of `radius_m` around the
/// point. The cell edge is at least twice the radius (and the cube
/// projection stretches edges by less than that), so the point's cell plus
/// its neighbours contain the cap. A radius of a quarter of the Earth's
/// circumference or more covers the whole sphere and returns one range.
/// `out` needs room for up to 9 ranges.
pub fn covering(lat: f64, lng: f64, radius_m: f64, out: []Range) Error![]Range {
    if (!std.math.isFinite(radius_m) or radius_m < 0) return error.RadiusOutOfRange;
    const quarter = (std.math.pi / 2.0) * earth_radius_m;
    if (radius_m >= quarter) {
        if (out.len == 0) return error.BufferTooSmall;
        out[0] = .{ .lo = Cell.fromFace(0).range().lo, .hi = Cell.fromFace(5).range().hi };
        return out[0..1];
    }
    const level_: u8 = if (radius_m == 0) max_level else blk: {
        const raw = @floor(std.math.log2(quarter / radius_m)) - 1;
        const clamped = std.math.clamp(raw, 0, @as(f64, @floatFromInt(max_level)));
        break :blk @intFromFloat(clamped);
    };
    const center = try atLevel(lat, lng, level_);
    var cells: [9]Cell = undefined;
    const n = neighborhood(center, &cells);
    var ranges: [9]Range = undefined;
    for (cells[0..n], 0..) |c, i| ranges[i] = c.range();
    std.mem.sort(Range, ranges[0..n], {}, struct {
        fn less(_: void, a: Range, b: Range) bool {
            return a.lo < b.lo;
        }
    }.less);
    var merged: usize = 0;
    for (ranges[0..n]) |r| {
        if (merged > 0 and r.lo <= ranges[merged - 1].hi + 1) {
            ranges[merged - 1].hi = @max(ranges[merged - 1].hi, r.hi);
        } else {
            ranges[merged] = r;
            merged += 1;
        }
    }
    if (out.len < merged) return error.BufferTooSmall;
    @memcpy(out[0..merged], ranges[0..merged]);
    return out[0..merged];
}

fn lsb(id: u64) u64 {
    return id & (~id +% 1);
}

fn lsbForLevel(level_: u8) u64 {
    return @as(u64, 1) << @intCast(2 * (@as(u8, max_level) - level_));
}

fn sizeIJ(level_: u8) i32 {
    return @as(i32, 1) << @intCast(max_level - level_);
}

fn hilbertPos(face_: u32, i: u32, j: u32) u64 {
    const chunk: u4 = 6;
    const T = curve2d.Tables(chunk);
    const chunks = 5;
    const mask: u32 = (@as(u32, 1) << chunk) - 1;
    var state: u32 = face_ & 1;
    var index: u64 = 0;
    inline for (0..chunks) |k| {
        const shift: u5 = @intCast((chunks - 1 - k) * chunk);
        const slot = (state << (2 * chunk)) | (((i >> shift) & mask) << chunk) | ((j >> shift) & mask);
        const entry: u32 = T.encode[slot];
        index = (index << (2 * chunk)) | (entry & ((@as(u32, 1) << (2 * chunk)) - 1));
        state = entry >> (2 * chunk);
    }
    return index;
}

fn posToIJ(face_: u32, pos60: u64) struct { i: u32, j: u32 } {
    const chunk: u4 = 6;
    const T = curve2d.Tables(chunk);
    const chunks = 5;
    const digit_mask: u64 = (@as(u64, 1) << (2 * chunk)) - 1;
    const coord_mask: u32 = (@as(u32, 1) << chunk) - 1;
    var state: u32 = face_ & 1;
    var x: u64 = 0;
    var y: u64 = 0;
    inline for (0..chunks) |k| {
        const shift: u6 = @intCast(2 * (chunks - 1 - k) * chunk);
        const slot = (state << (2 * chunk)) | @as(u32, @intCast((pos60 >> shift) & digit_mask));
        const entry: u32 = T.decode[slot];
        x = (x << chunk) | ((entry >> chunk) & coord_mask);
        y = (y << chunk) | (entry & coord_mask);
        state = entry >> (2 * chunk);
    }
    return .{ .i = @intCast(x), .j = @intCast(y) };
}

fn toFaceIJ(cell: Cell, i: *i32, j: *i32) u3 {
    const ij = posToIJ(cell.face(), (cell.id >> 1) & ((@as(u64, 1) << 60) - 1));
    i.* = @intCast(ij.i);
    j.* = @intCast(ij.j);
    return cell.face();
}

fn stToIJ(s: f64) u32 {
    if (!(s > 0)) return 0;
    const limit: f64 = @floatFromInt(max_size);
    const ij: i32 = @intFromFloat(limit * s);
    return @intCast(@min(ij, max_size - 1));
}

fn uvToSt(u: f64) f64 {
    if (u >= 0) return 0.5 * @sqrt(1 + 3 * u);
    return 1 - 0.5 * @sqrt(1 - 3 * u);
}

fn stToUv(s: f64) f64 {
    if (s >= 0.5) return (1.0 / 3.0) * (4 * s * s - 1);
    return (1.0 / 3.0) * (1 - 4 * (1 - s) * (1 - s));
}

fn siTiToSt(si: u32) f64 {
    return @as(f64, @floatFromInt(si)) / 2147483648.0;
}

const Xyz = struct { x: f64, y: f64, z: f64 };

fn faceUvToXyz(face_: i32, u: f64, v: f64) Xyz {
    return switch (face_) {
        0 => .{ .x = 1, .y = u, .z = v },
        1 => .{ .x = -u, .y = 1, .z = v },
        2 => .{ .x = -u, .y = -v, .z = 1 },
        3 => .{ .x = -1, .y = -v, .z = -u },
        4 => .{ .x = v, .y = -1, .z = -u },
        else => .{ .x = v, .y = u, .z = -1 },
    };
}

fn largestAbs(x: f64, y: f64, z: f64) u3 {
    const ax = @abs(x);
    const ay = @abs(y);
    const az = @abs(z);
    if (ax > ay) return if (ax > az) 0 else 2;
    return if (ay > az) 1 else 2;
}

fn xyzToFaceUv(x: f64, y: f64, z: f64, u: *f64, v: *f64) u3 {
    const comp = largestAbs(x, y, z);
    const p = [3]f64{ x, y, z };
    const face_: u3 = if (p[comp] < 0) comp + 3 else comp;
    switch (face_) {
        0 => {
            u.* = y / x;
            v.* = z / x;
        },
        1 => {
            u.* = -x / y;
            v.* = z / y;
        },
        2 => {
            u.* = -x / z;
            v.* = -y / z;
        },
        3 => {
            u.* = z / x;
            v.* = y / x;
        },
        4 => {
            u.* = z / y;
            v.* = -x / y;
        },
        5 => {
            u.* = -y / z;
            v.* = -x / z;
        },
        else => unreachable,
    }
    return face_;
}

fn fromFaceIJWrap(face_in: i32, i_in: i32, j_in: i32) Cell {
    const i = std.math.clamp(i_in, -1, max_size);
    const j = std.math.clamp(j_in, -1, max_size);
    const scale: f64 = 1.0 / @as(f64, @floatFromInt(max_size));
    const limit = 1.0 + std.math.floatEps(f64);
    const half: i32 = @divFloor(max_size, 2);
    const u = std.math.clamp(scale * @as(f64, @floatFromInt(2 * (i - half) + 1)), -limit, limit);
    const v = std.math.clamp(scale * @as(f64, @floatFromInt(2 * (j - half) + 1)), -limit, limit);
    const p = faceUvToXyz(face_in, u, v);
    var uu: f64 = undefined;
    var vv: f64 = undefined;
    const face_ = xyzToFaceUv(p.x, p.y, p.z, &uu, &vv);
    return Cell.fromFaceIJ(face_, stToIJ(0.5 * (uu + 1)), stToIJ(0.5 * (vv + 1)));
}

fn cellAt(face_: u3, i: i32, j: i32, level_: u8) Cell {
    const leaf_ = if (i >= 0 and i < max_size and j >= 0 and j < max_size)
        Cell.fromFaceIJ(face_, @intCast(i), @intCast(j))
    else
        fromFaceIJWrap(face_, i, j);
    return leaf_.parent(level_);
}

fn neighborhood(cell: Cell, out: *[9]Cell) usize {
    const level_ = cell.level();
    const size = sizeIJ(level_);
    var i: i32 = undefined;
    var j: i32 = undefined;
    const f = toFaceIJ(cell, &i, &j);
    var n: usize = 0;
    const deltas = [_]i32{ -size, 0, size };
    for (deltas) |dj| for (deltas) |di| {
        const c = cellAt(f, i + di, j + dj, level_);
        var seen = false;
        for (out[0..n]) |prev| seen = seen or prev.id == c.id;
        if (!seen) {
            out[n] = c;
            n += 1;
        }
    };
    return n;
}

test "face 0 leaf ids are the table encoder, and every face round-trips" {
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    for (0..500) |_| {
        const i = r.int(u32) >> 2;
        const j = r.int(u32) >> 2;
        const cell = Cell.fromFaceIJ(0, i, j);
        try std.testing.expectEqual((curve2d.encode(30, i, j) << 1) | 1, cell.id);
        var ii: i32 = undefined;
        var jj: i32 = undefined;
        for (0..6) |f| {
            const c = Cell.fromFaceIJ(@intCast(f), i, j);
            try std.testing.expectEqual(@as(u3, @intCast(f)), toFaceIJ(c, &ii, &jj));
            try std.testing.expectEqual(i, @as(u32, @intCast(ii)));
            try std.testing.expectEqual(j, @as(u32, @intCast(jj)));
            try std.testing.expect(c.valid() and c.leaf());
        }
    }
}

test "published parent, child, and face relationships" {
    const id = try Cell.fromFacePosLevel(3, 0x12345678, 26);
    try std.testing.expect(id.valid());
    try std.testing.expectEqual(@as(u3, 3), id.face());
    try std.testing.expectEqual(@as(u64, 0x12345700), id.pos());
    try std.testing.expectEqual(@as(u8, 26), id.level());
    try std.testing.expectEqual(@as(u64, 0x12345610), id.child(0).child(0).pos());
    try std.testing.expectEqual(@as(u64, 0x12345640), id.child(0).pos());
    try std.testing.expectEqual(@as(u64, 0x12345400), id.parent(25).pos());
    try std.testing.expectEqual(@as(u64, 0x12345000), id.parent(24).pos());
    try std.testing.expect(id.child(0).id < id.id and id.child(3).id > id.id);
    const span = id.range();
    try std.testing.expectEqual(2 * id.id, span.lo + span.hi);
    try std.testing.expect(id.contains(id.child(0)) and id.contains(id.child(3)));

    const poles = [_]struct { lat: f64, lng: f64, face: u3 }{
        .{ .lat = 0, .lng = 0, .face = 0 },
        .{ .lat = 0, .lng = 90, .face = 1 },
        .{ .lat = 90, .lng = 0, .face = 2 },
        .{ .lat = 0, .lng = 180, .face = 3 },
        .{ .lat = 0, .lng = -90, .face = 4 },
        .{ .lat = -90, .lng = 0, .face = 5 },
    };
    const leaves = [_]struct { lat: f64, lng: f64, face: u3, id: u64 }{
        .{ .lat = 0, .lng = 0, .face = 0, .id = 1152921504606846977 },
        .{ .lat = 0, .lng = 90, .face = 1, .id = 3458764513820540929 },
        .{ .lat = 90, .lng = 0, .face = 2, .id = 5764607523034234881 },
        .{ .lat = 0, .lng = 180, .face = 3, .id = 8070450532247928831 },
        .{ .lat = 0, .lng = -90, .face = 4, .id = 10376293541461622785 },
        .{ .lat = -90, .lng = 0, .face = 5, .id = 12682136550675316737 },
        .{ .lat = 37.4, .lng = -122.1, .face = 4, .id = 9263817276881359979 },
        .{ .lat = -33.9, .lng = 151.2, .face = 3, .id = 7715424573867261831 },
        .{ .lat = 89, .lng = 10, .face = 2, .id = 4996161554607737651 },
        .{ .lat = -45, .lng = 179, .face = 5, .id = 12106205811951962285 },
        .{ .lat = 0.1, .lng = 0.1, .face = 0, .id = 1152926196071403833 },
    };
    for (leaves) |p| {
        const leaf_ = try fromLatLng(p.lat, p.lng);
        try std.testing.expectEqual(p.id, leaf_.id);
        try std.testing.expectEqual(p.face, leaf_.face());
    }
    for (poles) |p| {
        try std.testing.expectEqual(p.face, Cell.fromFace(p.face).face());
        try std.testing.expectEqual(@as(u8, 0), Cell.fromFace(p.face).level());
    }

    var buf: [16]u8 = undefined;
    var buf2: [16]u8 = undefined;
    const text = id.token(&buf);
    try std.testing.expectEqualStrings(text, (try fromToken(text)).token(&buf2));
    try std.testing.expectError(error.InvalidCell, fromToken("876bee99\n"));
    try std.testing.expectError(error.LatitudeOutOfRange, fromLatLng(91, 0));
    try std.testing.expectError(error.NonFinite, fromLatLng(std.math.nan(f64), 0));
}

test "centers, neighbours, and coverings stay on the sphere" {
    const samples = [_]LatLng{
        .{ .lat = 37.4, .lng = -122.1 },
        .{ .lat = -33.9, .lng = 151.2 },
        .{ .lat = 0.1, .lng = 0.1 },
        .{ .lat = 89, .lng = 10 },
        .{ .lat = -45, .lng = 179 },
    };
    for (samples) |s| {
        const leaf_ = try fromLatLng(s.lat, s.lng);
        const back = leaf_.center();
        try std.testing.expect(@abs(back.lat - s.lat) < 0.001);
        const dlng = @abs(back.lng - s.lng);
        try std.testing.expect(@min(dlng, 360 - dlng) < 0.001);

        const nbrs = leaf_.parent(12).edgeNeighbors();
        for (nbrs) |n| {
            try std.testing.expect(n.valid() and n.level() == 12 and n.id != leaf_.parent(12).id);
        }

        var ranges: [9]Range = undefined;
        const got = try covering(s.lat, s.lng, 1000, &ranges);
        try std.testing.expect(got.len >= 1 and got.len <= 9);
        var inside = false;
        for (got) |r| inside = inside or (leaf_.id >= r.lo and leaf_.id <= r.hi);
        try std.testing.expect(inside);
        for (got[1..]) |r| try std.testing.expect(r.lo > got[0].lo);
    }

    var one: [1]Range = undefined;
    const whole = try covering(10, 20, earth_radius_m * 2, &one);
    try std.testing.expectEqual(@as(usize, 1), whole.len);
    try std.testing.expect((try fromLatLng(-40, 70)).id >= whole[0].lo);
    try std.testing.expectError(error.BufferTooSmall, covering(10, 20, 50, one[0..0]));
}
