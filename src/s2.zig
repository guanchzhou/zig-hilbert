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
    CoverOptionsOutOfRange,
    RegionOutOfRange,
    CoverTooLarge,
    UnsortedCells,
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
        return max_level -| @as(u8, @intCast(@ctz(self.id) >> 1));
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
        const new_lsb = lsb(self.id) >> 2;
        const delta = (@as(u64, 2) * position +% 1 -% 4) *% new_lsb;
        return .{ .id = self.id +% delta };
    }

    pub fn children(self: Cell) [4]Cell {
        return .{ self.child(0), self.child(1), self.child(2), self.child(3) };
    }

    /// Id 0 (`fromToken("X")`) is not a cell; its range holds only id 0.
    pub fn range(self: Cell) Range {
        const bit = lsb(self.id);
        if (bit == 0) return .{ .lo = 0, .hi = 0 };
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
        const iu: u32 = @intCast(i);
        const ju: u32 = @intCast(j);
        const low: u32 = @intCast((self.id >> 2) & 1);
        const delta: u32 = if (self.leaf()) 1 else if (((iu ^ low) & 1) == 1) 2 else 0;
        const u = stToUv(siTiToSt(2 * iu + delta));
        const v = stToUv(siTiToSt(2 * ju + delta));
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
    /// `face` is at most 5 and `pos` fits in 61 bits.
    pub fn fromFacePosLevel(face_: u3, pos_: u64, level_: u8) Error!Cell {
        if (level_ > max_level) return error.LevelOutOfRange;
        if (face_ > 5 or pos_ >> 61 != 0) return error.InvalidCell;
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
    if (!std.math.isFinite(lat) or !std.math.isFinite(lng)) return error.NonFinite;
    if (lat < -90 or lat > 90) return error.LatitudeOutOfRange;
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

/// Limits for `cover`. `max_cells` is a desired maximum: a region that meets
/// more than that many cube faces still returns one cell per face.
pub const CoverOptions = struct {
    min_level: u8 = 0,
    max_level: u8 = 16,
    max_cells: u16 = 8,
};

/// A region the coverer can ask two questions about. `mayIntersect` must be
/// true whenever the cell meets the region. `contains` is true only when
/// every point of the cell is inside the region.
pub const Region = struct {
    ctx: *const anyopaque,
    mayIntersect: *const fn (ctx: *const anyopaque, cell: Cell) bool,
    contains: *const fn (ctx: *const anyopaque, cell: Cell) bool,
};

const max_cover_scratch = 2048;

fn coverCellBefore(a: Cell, b: Cell) bool {
    const la = a.level();
    const lb = b.level();
    return la < lb or (la == lb and a.id < b.id);
}

fn heapPushCell(heap: []Cell, n: *usize, cell: Cell) void {
    var i = n.*;
    heap[i] = cell;
    n.* = i + 1;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (!coverCellBefore(heap[i], heap[parent])) break;
        std.mem.swap(Cell, &heap[parent], &heap[i]);
        i = parent;
    }
}

fn heapPopCell(heap: []Cell, n: *usize) Cell {
    const top = heap[0];
    n.* -= 1;
    const len = n.*;
    if (len > 0) {
        heap[0] = heap[len];
        var i: usize = 0;
        while (true) {
            var smallest = i;
            const left = 2 * i + 1;
            const right = 2 * i + 2;
            if (left < len and coverCellBefore(heap[left], heap[smallest])) smallest = left;
            if (right < len and coverCellBefore(heap[right], heap[smallest])) smallest = right;
            if (smallest == i) break;
            std.mem.swap(Cell, &heap[i], &heap[smallest]);
            i = smallest;
        }
    }
    return top;
}

/// Cells covering `region`, sorted by id. `out` must hold at least
/// `max(opts.max_cells, 6)` cells, and more with `min_level`, which can
/// exceed `max_cells`. Each edge of a polyline or polygon is the shorter arc
/// between its endpoints. Every intersecting cell above `min_level` is
/// expanded in a fixed 2048-cell queue; a region that meets more cells than
/// that at `min_level` returns `error.CoverTooLarge`.
pub fn cover(region: Region, opts: CoverOptions, out: []Cell) Error![]Cell {
    if (opts.max_cells == 0 or opts.min_level > opts.max_level or opts.max_level > max_level) {
        return error.CoverOptionsOutOfRange;
    }
    var scratch: [max_cover_scratch]Cell = undefined;
    var n: usize = 0;
    for (0..6) |face_| {
        const cell = Cell.fromFace(@intCast(face_));
        if (region.mayIntersect(region.ctx, cell)) {
            heapPushCell(&scratch, &n, cell);
        }
    }

    var result_n: usize = 0;
    while (n > 0) {
        const cell = heapPopCell(&scratch, &n);

        if (cell.level() < opts.min_level) {
            for (cell.children()) |child_| {
                if (!region.mayIntersect(region.ctx, child_)) continue;
                if (n >= scratch.len) return error.CoverTooLarge;
                heapPushCell(&scratch, &n, child_);
            }
            continue;
        }

        const stop = region.contains(region.ctx, cell) or cell.level() >= opts.max_level;
        if (stop) {
            if (result_n >= out.len) return error.BufferTooSmall;
            out[result_n] = cell;
            result_n += 1;
            continue;
        }

        var hit: [4]Cell = undefined;
        var hn: usize = 0;
        for (cell.children()) |child_| {
            if (region.mayIntersect(region.ctx, child_)) {
                hit[hn] = child_;
                hn += 1;
            }
        }
        if (hn == 0) continue;
        if (result_n + n + hn > opts.max_cells or n + hn > scratch.len) {
            if (result_n >= out.len) return error.BufferTooSmall;
            out[result_n] = cell;
            result_n += 1;
        } else {
            for (hit[0..hn]) |child_| {
                heapPushCell(&scratch, &n, child_);
            }
        }
    }

    std.mem.sort(Cell, out[0..result_n], {}, struct {
        fn less(_: void, a: Cell, b: Cell) bool {
            return a.id < b.id;
        }
    }.less);
    return out[0..result_n];
}

/// Merge `cells` (sorted by id) into inclusive id ranges. Every cell must be
/// valid and `cells` must be sorted in non-decreasing id order.
pub fn mergeRanges(cells: []const Cell, out: []Range) Error![]Range {
    var n: usize = 0;
    var prev_id: u64 = 0;
    for (cells, 0..) |cell, idx| {
        if (!cell.valid()) return error.InvalidCell;
        if (idx > 0 and cell.id < prev_id) return error.UnsortedCells;
        prev_id = cell.id;
        var r = cell.range();
        while (n > 0 and r.lo <= out[n - 1].hi + 1 and out[n - 1].lo <= r.hi + 1) {
            r.lo = @min(r.lo, out[n - 1].lo);
            r.hi = @max(r.hi, out[n - 1].hi);
            n -= 1;
        }
        if (n >= out.len) return error.BufferTooSmall;
        out[n] = r;
        n += 1;
    }
    return out[0..n];
}

/// Cells covering the cap of `radius_m` around the point.
pub fn coverCap(lat: f64, lng: f64, radius_m: f64, opts: CoverOptions, out: []Cell) Error![]Cell {
    if (!std.math.isFinite(radius_m) or radius_m < 0) return error.RadiusOutOfRange;
    const cap = Cap{
        .center = try latLngToXyz(lat, lng),
        .angle = @min(radius_m / earth_radius_m, std.math.pi),
    };
    return cover(cap.region(), opts, out);
}

/// Cells covering the shorter arcs through `points`, in order.
pub fn coverPolyline(points: []const LatLng, opts: CoverOptions, out: []Cell) Error![]Cell {
    if (points.len == 0) return out[0..0];
    var verts: [max_region_verts]Xyz = undefined;
    const line = try xyzVerts(points, &verts);
    return cover(line.region(), opts, out);
}

/// Cells covering the interior of a simple ring. `points` has at least 3
/// vertices; a repeated closing vertex is ignored.
pub fn coverPolygon(points: []const LatLng, opts: CoverOptions, out: []Cell) Error![]Cell {
    var verts: [max_region_verts]Xyz = undefined;
    const ring = try polygonVerts(points, &verts);
    return cover(ring.region(), opts, out);
}

fn lsb(id: u64) u64 {
    return id & (~id +% 1);
}

fn lsbForLevel(level_: u8) u64 {
    return @as(u64, 1) << @intCast(2 * (@as(u8, max_level) -| level_));
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

pub const max_region_verts = 4096;

const Cap = struct {
    center: Xyz,
    angle: f64,

    fn region(self: *const Cap) Region {
        return .{
            .ctx = @ptrCast(self),
            .mayIntersect = mayIntersect,
            .contains = containsCell,
        };
    }

    fn mayIntersect(ctx: *const anyopaque, cell: Cell) bool {
        const self: *const Cap = @ptrCast(@alignCast(ctx));
        const bound = cellCap(cell);
        return angleBetween(self.center, bound.center) <= self.angle + bound.angle;
    }

    fn containsCell(ctx: *const anyopaque, cell: Cell) bool {
        const self: *const Cap = @ptrCast(@alignCast(ctx));
        const bound = cellCap(cell);
        return angleBetween(self.center, bound.center) + bound.angle <= self.angle;
    }
};

const Polyline = struct {
    pts: []const Xyz,

    fn region(self: *const Polyline) Region {
        return .{
            .ctx = @ptrCast(self),
            .mayIntersect = mayIntersect,
            .contains = containsCell,
        };
    }

    fn mayIntersect(ctx: *const anyopaque, cell: Cell) bool {
        const self: *const Polyline = @ptrCast(@alignCast(ctx));
        return chainHits(self.pts, cell, false);
    }

    fn containsCell(_: *const anyopaque, _: Cell) bool {
        return false;
    }
};

const Polygon = struct {
    pts: []const Xyz,
    origin: Xyz,
    origin_inside: bool,
    degenerate: bool,

    fn region(self: *const Polygon) Region {
        return .{
            .ctx = @ptrCast(self),
            .mayIntersect = mayIntersect,
            .contains = containsCell,
        };
    }

    fn mayIntersect(ctx: *const anyopaque, cell: Cell) bool {
        const self: *const Polygon = @ptrCast(@alignCast(ctx));
        const r = cellRect(cell);
        for (self.pts) |p| if (rectContainsPoint(r, p)) return true;
        const v = rectVertices(r);
        if (chainSegmentsHitVerts(self.pts, v, true)) return true;
        if (self.pts.len < 3 or self.degenerate) return false;
        return self.containsPoint(vertsCenter(v));
    }

    fn containsCell(ctx: *const anyopaque, cell: Cell) bool {
        const self: *const Polygon = @ptrCast(@alignCast(ctx));
        if (self.pts.len < 3 or self.degenerate) return false;
        const r = cellRect(cell);
        for (self.pts) |p| if (rectContainsPoint(r, p)) return false;
        const v = rectVertices(r);
        if (chainSegmentsHitVerts(self.pts, v, true)) return false;
        return self.containsPoint(vertsCenter(v));
    }

    fn containsPoint(self: *const Polygon, p: Xyz) bool {
        if (self.degenerate) return false;
        var inside = self.origin_inside;
        if (dot(self.origin, p) < -0.5) {
            const ref: Xyz = if (@abs(self.origin.x) < 0.9) .{ .x = 1, .y = 0, .z = 0 } else .{ .x = 0, .y = 1, .z = 0 };
            const mid = normalize(cross(self.origin, ref));
            if (toggleCrossings(self.pts, self.origin, mid, null)) inside = !inside;
            if (toggleCrossings(self.pts, mid, p, null)) inside = !inside;
        } else {
            if (toggleCrossings(self.pts, self.origin, p, null)) inside = !inside;
        }
        return inside;
    }
};

fn xyzVerts(points: []const LatLng, buf: []Xyz) Error!Polyline {
    if (points.len > buf.len) return error.BufferTooSmall;
    for (points, 0..) |p, i| buf[i] = try latLngToXyz(p.lat, p.lng);
    return .{ .pts = buf[0..points.len] };
}

fn polygonSignedTurn(pts: []const Xyz) f64 {
    var sum: f64 = 0;
    const n = pts.len;
    for (0..n) |i| {
        const prev = pts[(i + n - 1) % n];
        const cur = pts[i];
        const next = pts[(i + 1) % n];
        const e_prev = cross(prev, cur);
        const e_next = cross(cur, next);
        const l1 = @sqrt(dot(e_prev, e_prev));
        const l2 = @sqrt(dot(e_next, e_next));
        if (l1 == 0 or l2 == 0) continue;
        const n1 = Xyz{ .x = e_prev.x / l1, .y = e_prev.y / l1, .z = e_prev.z / l1 };
        const n2 = Xyz{ .x = e_next.x / l2, .y = e_next.y / l2, .z = e_next.z / l2 };
        sum += std.math.atan2(dot(cur, cross(n1, n2)), dot(n1, n2));
    }
    return sum;
}

fn orderedCCW(a: Xyz, b: Xyz, c: Xyz, o: Xyz) bool {
    var sum: u8 = 0;
    if (dot(cross(b, o), a) >= 0) sum += 1;
    if (dot(cross(c, o), b) >= 0) sum += 1;
    if (dot(cross(a, o), c) > 0) sum += 1;
    return sum >= 2;
}

fn chooseOrigin(pts: []const Xyz, anchor: Xyz) Xyz {
    const candidates = [_]Xyz{
        normalize(.{ .x = -0.0099994664350250197, .y = 0.0025924542609324121, .z = 0.99994664350250195 }),
        normalize(.{ .x = 0.9999123412341234, .y = 0.0112345678901234, .z = -0.0069876543210987 }),
        normalize(.{ .x = -0.0087654321098765, .y = 0.9999345678901234, .z = 0.0073456789012345 }),
        normalize(.{ .x = 0.5771234567890123, .y = -0.5774567890123456, .z = 0.5774689012345678 }),
    };
    var best = candidates[0];
    var best_score: f64 = -1;
    for (candidates) |cand| {
        if (@abs(dot(cand, anchor)) > 0.85) continue;
        var min_edge: f64 = 1.0;
        for (pts, 0..) |a, i| {
            const b = pts[(i + 1) % pts.len];
            const e = cross(a, b);
            const el = @sqrt(dot(e, e));
            if (el == 0) continue;
            min_edge = @min(min_edge, @abs(dot(e, cand)) / el);
        }
        if (min_edge > best_score) {
            best_score = min_edge;
            best = cand;
        }
    }
    return best;
}

fn polygonVerts(points: []const LatLng, buf: []Xyz) Error!Polygon {
    if (points.len < 3) return error.RegionOutOfRange;
    var n = points.len;
    const last = points[n - 1];
    const first = points[0];
    if (last.lat == first.lat and last.lng == first.lng) n -= 1;
    if (n < 3) return error.RegionOutOfRange;
    if (n > buf.len) return error.BufferTooSmall;
    for (points[0..n], 0..) |p, i| buf[i] = try latLngToXyz(p.lat, p.lng);
    const pts = buf[0..n];
    // Orient CCW around the smaller interior (area <= 2*pi).
    if (polygonSignedTurn(pts) < 0) std.mem.reverse(Xyz, pts);

    // Pick a non-degenerate vertex as anchor to determine origin_inside.
    var anchor_idx: ?usize = null;
    for (0..n) |i| {
        const prev = pts[(i + n - 1) % n];
        const cur = pts[i];
        const next = pts[(i + 1) % n];
        if (dot(cross(prev, cur), cross(prev, cur)) > 0 and dot(cross(cur, next), cross(cur, next)) > 0) {
            anchor_idx = i;
            break;
        }
    }
    const ai = anchor_idx orelse return .{ .pts = pts, .origin = .{ .x = 0, .y = 0, .z = 1 }, .origin_inside = false, .degenerate = true };
    const prev_i = (ai + n - 1) % n;
    const next_i = (ai + 1) % n;
    const origin = chooseOrigin(pts, pts[ai]);
    var origin_inside = orderedCCW(pts[next_i], origin, pts[prev_i], pts[ai]);
    if (toggleCrossings(pts, pts[ai], origin, .{ .prev = prev_i, .cur = ai })) origin_inside = !origin_inside;
    return .{ .pts = pts, .origin = origin, .origin_inside = origin_inside, .degenerate = false };
}

fn latLngToXyz(lat: f64, lng: f64) Error!Xyz {
    if (!std.math.isFinite(lat) or !std.math.isFinite(lng)) return error.NonFinite;
    if (lat < -90 or lat > 90) return error.LatitudeOutOfRange;
    const phi = lat * (std.math.pi / 180.0);
    const theta = lng * (std.math.pi / 180.0);
    const cos_phi = @cos(phi);
    return .{ .x = cos_phi * @cos(theta), .y = cos_phi * @sin(theta), .z = @sin(phi) };
}

fn normalize(p: Xyz) Xyz {
    const len = @sqrt(dot(p, p));
    return .{ .x = p.x / len, .y = p.y / len, .z = p.z / len };
}

fn add(a: Xyz, b: Xyz) Xyz {
    return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
}

fn dot(a: Xyz, b: Xyz) f64 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

fn cross(a: Xyz, b: Xyz) Xyz {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x,
    };
}

fn angleBetween(a: Xyz, b: Xyz) f64 {
    return std.math.acos(std.math.clamp(dot(a, b), -1.0, 1.0));
}

const CellRect = struct { face: u3, i0: i32, j0: i32, i1: i32, j1: i32 };

fn cellRect(cell: Cell) CellRect {
    var i: i32 = undefined;
    var j: i32 = undefined;
    const face_ = toFaceIJ(cell, &i, &j);
    const size = sizeIJ(cell.level());
    const mask = ~(size - 1);
    const lo_i = i & mask;
    const lo_j = j & mask;
    return .{
        .face = face_,
        .i0 = lo_i,
        .j0 = lo_j,
        .i1 = lo_i + size,
        .j1 = lo_j + size,
    };
}

fn ijToXyz(face_: u3, i: i32, j: i32) Xyz {
    const limit: f64 = @floatFromInt(max_size);
    const s = std.math.clamp(@as(f64, @floatFromInt(i)) / limit, 0.0, 1.0);
    const t = std.math.clamp(@as(f64, @floatFromInt(j)) / limit, 0.0, 1.0);
    return normalize(faceUvToXyz(face_, stToUv(s), stToUv(t)));
}

fn rectVertices(r: CellRect) [4]Xyz {
    return .{
        ijToXyz(r.face, r.i0, r.j0),
        ijToXyz(r.face, r.i1, r.j0),
        ijToXyz(r.face, r.i1, r.j1),
        ijToXyz(r.face, r.i0, r.j1),
    };
}

fn cellVertices(cell: Cell) [4]Xyz {
    return rectVertices(cellRect(cell));
}

fn vertsCenter(v: [4]Xyz) Xyz {
    var sum = Xyz{ .x = 0, .y = 0, .z = 0 };
    for (v) |p| {
        sum.x += p.x;
        sum.y += p.y;
        sum.z += p.z;
    }
    return normalize(sum);
}

fn cellCap(cell: Cell) Cap {
    const v = cellVertices(cell);
    const center = vertsCenter(v);
    var ang: f64 = 0;
    for (v) |p| ang = @max(ang, angleBetween(center, p));
    return .{ .center = center, .angle = ang };
}

fn pointIJ(p: Xyz) struct { face: u3, i: i32, j: i32 } {
    var u: f64 = undefined;
    var v: f64 = undefined;
    const face_ = xyzToFaceUv(p.x, p.y, p.z, &u, &v);
    return .{
        .face = face_,
        .i = @intCast(stToIJ(uvToSt(u))),
        .j = @intCast(stToIJ(uvToSt(v))),
    };
}

fn rectContainsPoint(r: CellRect, p: Xyz) bool {
    const q = pointIJ(p);
    return q.face == r.face and q.i >= r.i0 and q.i < r.i1 and q.j >= r.j0 and q.j < r.j1;
}

fn pointOnArc(x: Xyz, a: Xyz, b: Xyz, ab: Xyz) bool {
    return dot(cross(a, x), ab) >= 0 and dot(cross(x, b), ab) >= 0 and dot(x, add(a, b)) > 0;
}

fn arcsCross(a: Xyz, b: Xyz, c: Xyz, d: Xyz) bool {
    const ab = cross(a, b);
    const cd = cross(c, d);
    if (dot(ab, ab) == 0 or dot(cd, cd) == 0) return false;
    const s1 = dot(ab, c);
    const s2 = dot(ab, d);
    const s3 = dot(cd, a);
    const s4 = dot(cd, b);
    if (s1 * s2 > 0 or s3 * s4 > 0) return false;
    if ((s1 == 0 and s2 == 0) or (s3 == 0 and s4 == 0)) {
        return pointOnArc(c, a, b, ab) or pointOnArc(d, a, b, ab) or
            pointOnArc(a, c, d, cd) or pointOnArc(b, c, d, cd);
    }
    // For non-collinear arcs, intersection p = ab x cd satisfies
    // dot(p, a+b) = (s3 - s4)(1 + a.b) and dot(p, c+d) = (s2 - s1)(1 + c.d).
    // Both shorter arcs meet at the same point iff those have the same sign.
    return (s3 - s4) * (s2 - s1) > 0;
}

fn rayCrossesEdge(a: Xyz, b: Xyz, c: Xyz, d: Xyz) bool {
    const ab = cross(a, b);
    const cd = cross(c, d);
    if (dot(ab, ab) == 0 or dot(cd, cd) == 0) return false;
    const s1 = dot(ab, c);
    const s2 = dot(ab, d);
    if ((s1 < 0) == (s2 < 0)) return false;
    const s3 = dot(cd, a);
    const s4 = dot(cd, b);
    if ((s3 < 0) == (s4 < 0)) return false;
    return (s3 - s4) * (s2 - s1) > 0;
}

fn toggleCrossings(pts: []const Xyz, a: Xyz, b: Xyz, skip: ?struct { prev: usize, cur: usize }) bool {
    var odd = false;
    const n = pts.len;
    for (0..n) |i| {
        if (skip) |sk| if (i == sk.prev or i == sk.cur) continue;
        if (rayCrossesEdge(a, b, pts[i], pts[(i + 1) % n])) odd = !odd;
    }
    return odd;
}

fn segmentHitsVerts(a: Xyz, b: Xyz, v: [4]Xyz) bool {
    for (0..4) |k| {
        if (arcsCross(a, b, v[k], v[(k + 1) % 4])) return true;
    }
    return false;
}

fn chainSegmentsHitVerts(pts: []const Xyz, v: [4]Xyz, closed: bool) bool {
    if (pts.len < 2) return false;
    for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
        if (segmentHitsVerts(a, b, v)) return true;
    }
    if (closed and pts.len >= 3 and segmentHitsVerts(pts[pts.len - 1], pts[0], v)) return true;
    return false;
}

fn chainHits(pts: []const Xyz, cell: Cell, closed: bool) bool {
    if (pts.len == 0) return false;
    const r = cellRect(cell);
    for (pts) |p| if (rectContainsPoint(r, p)) return true;
    if (pts.len == 1) return false;
    const v = rectVertices(r);
    return chainSegmentsHitVerts(pts, v, closed);
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

fn cellCovers(cells: []const Cell, lat: f64, lng: f64) !bool {
    const leaf_ = try fromLatLng(lat, lng);
    for (cells) |cell| if (cell.contains(leaf_)) return true;
    return false;
}

test "region covers contain the cap, the line, and the polygon" {
    const opts = CoverOptions{ .max_level = 12, .max_cells = 32 };
    var out: [64]Cell = undefined;

    const cap = try coverCap(37.4, -122.1, 1000, opts, &out);
    try std.testing.expect(try cellCovers(cap, 37.4, -122.1));
    try std.testing.expect(!try cellCovers(cap, 0, 0));
    try std.testing.expect(cap.len <= opts.max_cells);

    const line = [_]LatLng{
        .{ .lat = 10, .lng = 10 },
        .{ .lat = 10.2, .lng = 10.3 },
        .{ .lat = 10.4, .lng = 10.1 },
    };
    const lined = try coverPolyline(&line, opts, &out);
    for (line) |p| try std.testing.expect(try cellCovers(lined, p.lat, p.lng));
    try std.testing.expect(try cellCovers(lined, 10.1, 10.15));
    try std.testing.expectEqual(@as(usize, 0), (try coverPolyline(line[0..0], opts, &out)).len);

    const ring = [_]LatLng{
        .{ .lat = 20, .lng = 20 },
        .{ .lat = 20, .lng = 20.2 },
        .{ .lat = 20.2, .lng = 20.1 },
    };
    const poly = try coverPolygon(&ring, opts, &out);
    try std.testing.expect(try cellCovers(poly, 20.05, 20.1));
    try std.testing.expect(!try cellCovers(poly, 0, 0));
    const closed = [_]LatLng{ ring[0], ring[1], ring[2], ring[0] };
    try std.testing.expect(try cellCovers(try coverPolygon(&closed, opts, &out), 20.05, 20.1));
    try std.testing.expectError(error.RegionOutOfRange, coverPolygon(ring[0..2], opts, &out));

    const only_face_0 = struct {
        fn mayIntersect(_: *const anyopaque, cell: Cell) bool {
            return cell.face() == 0;
        }
        fn contains(_: *const anyopaque, cell: Cell) bool {
            return cell.face() == 0 and cell.level() == 0;
        }
    };
    var dummy: u8 = 0;
    const got = try cover(.{
        .ctx = &dummy,
        .mayIntersect = only_face_0.mayIntersect,
        .contains = only_face_0.contains,
    }, .{}, &out);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(Cell.fromFace(0).id, got[0].id);

    var ranges: [64]Range = undefined;
    const merged = try mergeRanges(got, &ranges);
    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectEqual(got[0].range().lo, merged[0].lo);

    try std.testing.expectError(error.CoverOptionsOutOfRange, coverCap(0, 0, 1, .{ .min_level = 3, .max_level = 1 }, &out));
    try std.testing.expectError(error.BufferTooSmall, coverCap(0, 0, 1, opts, out[0..0]));
}

test "fromFacePosLevel rejects a face or position outside the cube" {
    try std.testing.expectError(error.InvalidCell, Cell.fromFacePosLevel(6, 0, 10));
    try std.testing.expectError(error.InvalidCell, Cell.fromFacePosLevel(7, 0, 10));
    try std.testing.expectError(error.InvalidCell, Cell.fromFacePosLevel(0, @as(u64, 1) << 61, 10));
    try std.testing.expectError(error.InvalidCell, Cell.fromFacePosLevel(5, std.math.maxInt(u64), 30));
    const last = try Cell.fromFacePosLevel(5, (@as(u64, 1) << 61) - 1, 30);
    try std.testing.expect(last.valid() and last.leaf() and last.face() == 5);
}

test "id 0 is safe to range, contain, and merge" {
    const zero = try fromToken("X");
    try std.testing.expectEqual(Range{ .lo = 0, .hi = 0 }, zero.range());
    try std.testing.expect(zero.contains(zero));
    try std.testing.expect(!zero.contains(Cell.fromFace(0)));
    try std.testing.expect(!Cell.fromFace(0).contains(zero));
    var ranges: [2]Range = undefined;
    try std.testing.expectError(error.InvalidCell, mergeRanges(&.{zero}, &ranges));
    try std.testing.expectError(error.InvalidCell, mergeRanges(&.{ Cell.fromFace(0), .{ .id = 3 << 61 | 1 << 59 } }, &ranges));
    try std.testing.expectError(error.InvalidCell, mergeRanges(&.{.{ .id = 7 << 61 | 1 }}, &ranges));
}

test "level and parent saturate on ids outside the documented domain" {
    const bad: Cell = .{ .id = 1 << 62 };
    try std.testing.expect(!bad.valid());
    try std.testing.expectEqual(@as(u8, 0), bad.level());
    const leaf_ = try fromLatLng(1, 2);
    try std.testing.expectEqual(leaf_.id, leaf_.parent(255).id);
}

test "a min_level beyond the expansion queue is a clear error" {
    var out: [8]Cell = undefined;
    const opts = CoverOptions{ .min_level = 6, .max_level = 6 };
    try std.testing.expectError(error.CoverTooLarge, coverCap(0, 0, earth_radius_m * 4, opts, &out));
}

test "cellRect aligns to exact power-of-two boundaries on all orientations" {
    for (0..6) |f| {
        const root = Cell.fromFace(@intCast(f));
        const r0 = cellRect(root);
        try std.testing.expectEqual(@as(i32, 0), r0.i0);
        try std.testing.expectEqual(@as(i32, 0), r0.j0);
        try std.testing.expectEqual(max_size, r0.i1);
        try std.testing.expectEqual(max_size, r0.j1);

        // Descend through all 4 children at several levels to hit both flip == 0 and flip == 1.
        for (root.children()) |c1| {
            for (c1.children()) |c2| {
                const size = sizeIJ(c2.level());
                const r = cellRect(c2);
                try std.testing.expectEqual(@as(u3, @intCast(f)), r.face);
                try std.testing.expect(r.i0 >= 0 and r.j0 >= 0 and r.i1 <= max_size and r.j1 <= max_size);
                try std.testing.expectEqual(@as(i32, 0), @mod(r.i0, size));
                try std.testing.expectEqual(@as(i32, 0), @mod(r.j0, size));
                try std.testing.expectEqual(size, r.i1 - r.i0);
                try std.testing.expectEqual(size, r.j1 - r.j0);
                try std.testing.expect(c2.contains(Cell.fromFaceIJ(r.face, @intCast(r.i0), @intCast(r.j0))));
                try std.testing.expect(c2.contains(Cell.fromFaceIJ(r.face, @intCast(r.i1 - 1), @intCast(r.j1 - 1))));
            }
        }
    }
}

test "arcsCross rejects antipodal crossings and degenerate arcs" {
    const a = normalize(.{ .x = 0.1, .y = 0, .z = 1 });
    const b = normalize(.{ .x = -0.1, .y = 0, .z = 1 });
    const c_north = normalize(.{ .x = 0, .y = 0.1, .z = 1 });
    const d_north = normalize(.{ .x = 0, .y = -0.1, .z = 1 });
    const c_south = normalize(.{ .x = 0, .y = 0.1, .z = -1 });
    const d_south = normalize(.{ .x = 0, .y = -0.1, .z = -1 });

    // Same hemisphere crossing vs antipodal non-crossing.
    try std.testing.expect(arcsCross(a, b, c_north, d_north));
    try std.testing.expect(!arcsCross(a, b, c_south, d_south));

    // Degenerate zero-length and antipodal arcs must return false.
    try std.testing.expect(!arcsCross(a, a, c_north, d_north));
    try std.testing.expect(!arcsCross(a, b, c_north, c_north));
    try std.testing.expect(!arcsCross(a, .{ .x = -a.x, .y = -a.y, .z = -a.z }, c_north, d_north));

    // Shared endpoint vs antipodal endpoint.
    const eq0 = Xyz{ .x = 1, .y = 0, .z = 0 };
    const eq90 = Xyz{ .x = 0, .y = 1, .z = 0 };
    const eq180 = Xyz{ .x = -1, .y = 0, .z = 0 };
    const np = Xyz{ .x = 0, .y = 0, .z = 1 };
    try std.testing.expect(arcsCross(eq0, eq90, eq0, np));
    try std.testing.expect(!arcsCross(eq0, eq90, eq180, np));

    // Collinear overlapping vs collinear antipodal.
    const eq45 = normalize(.{ .x = 1, .y = 1, .z = 0 });
    const eq135 = normalize(.{ .x = -1, .y = 1, .z = 0 });
    const eq270 = Xyz{ .x = 0, .y = -1, .z = 0 };
    try std.testing.expect(arcsCross(eq0, eq90, eq45, eq135));
    try std.testing.expect(!arcsCross(eq0, eq90, eq180, eq270));
}

test "coverPolygon has no antipodal false positives for CCW, CW, polar, and concave rings" {
    const opts = CoverOptions{ .max_level = 10, .max_cells = 64 };
    var out: [64]Cell = undefined;

    // Small CCW triangle near (20, 20): antipode (-20, -160) must NOT be covered.
    const ccw = [_]LatLng{
        .{ .lat = 20, .lng = 20 },
        .{ .lat = 20, .lng = 22 },
        .{ .lat = 22, .lng = 21 },
    };
    const ccw_cells = try coverPolygon(&ccw, opts, &out);
    try std.testing.expect(try cellCovers(ccw_cells, 20.5, 21.0));
    try std.testing.expect(!try cellCovers(ccw_cells, -20.5, -159.0));
    try std.testing.expect(!try cellCovers(ccw_cells, -20.0, -160.0));

    // Same triangle reversed (CW): still covers small interior, not antipode or exterior.
    const cw = [_]LatLng{ ccw[0], ccw[2], ccw[1] };
    const cw_cells = try coverPolygon(&cw, opts, &out);
    try std.testing.expect(try cellCovers(cw_cells, 20.5, 21.0));
    try std.testing.expect(!try cellCovers(cw_cells, -20.5, -159.0));
    try std.testing.expect(!try cellCovers(cw_cells, 0, 0));

    // North Pole cap triangle: covers North Pole, NOT South Pole.
    const polar = [_]LatLng{
        .{ .lat = 80, .lng = 0 },
        .{ .lat = 80, .lng = 120 },
        .{ .lat = 80, .lng = -120 },
    };
    const polar_cells = try coverPolygon(&polar, opts, &out);
    try std.testing.expect(try cellCovers(polar_cells, 89.9, 0));
    try std.testing.expect(!try cellCovers(polar_cells, -89.9, 0));

    // Concave L-shape: covers both arms, excludes notch and antipode.
    const l_shape = [_]LatLng{
        .{ .lat = 10, .lng = 10 },
        .{ .lat = 10, .lng = 14 },
        .{ .lat = 11, .lng = 14 },
        .{ .lat = 11, .lng = 11 },
        .{ .lat = 14, .lng = 11 },
        .{ .lat = 14, .lng = 10 },
    };
    const l_cells = try coverPolygon(&l_shape, .{ .max_level = 12, .max_cells = 64 }, &out);
    try std.testing.expect(try cellCovers(l_cells, 10.5, 13.0));
    try std.testing.expect(try cellCovers(l_cells, 13.0, 10.5));
    try std.testing.expect(!try cellCovers(l_cells, 13.0, 13.0));
    try std.testing.expect(!try cellCovers(l_cells, -10.5, -167.0));
}

test "covering validates lat/lng even for whole-sphere radius" {
    var ranges: [9]Range = undefined;
    try std.testing.expectError(error.LatitudeOutOfRange, covering(91, 0, earth_radius_m * 4, &ranges));
    try std.testing.expectError(error.LatitudeOutOfRange, covering(-91, 0, earth_radius_m * 4, &ranges));
    try std.testing.expectError(error.NonFinite, covering(std.math.nan(f64), 0, earth_radius_m * 4, &ranges));
    try std.testing.expectError(error.NonFinite, covering(0, std.math.inf(f64), earth_radius_m * 4, &ranges));
}

test "mergeRanges rejects unsorted input and merges nested cells cleanly" {
    var ranges: [4]Range = undefined;
    try std.testing.expectError(error.UnsortedCells, mergeRanges(&.{ Cell.fromFace(5), Cell.fromFace(0) }, &ranges));
    const f0 = Cell.fromFace(0);
    try std.testing.expectError(error.UnsortedCells, mergeRanges(&.{ f0.child(2), f0.child(1) }, &ranges));

    // Sorted by id: child(1).id < parent.id, and parent subsumes child(1).
    const nested = try mergeRanges(&.{ f0.child(1), f0 }, &ranges);
    try std.testing.expectEqual(@as(usize, 1), nested.len);
    try std.testing.expectEqual(f0.range(), nested[0]);
}

test "Cell.child and Cell.center avoid signed overflow on high faces and corners" {
    for ([_]u3{ 4, 5 }) |f| {
        const root = Cell.fromFace(f);
        for (0..4) |pos_| {
            const c = root.child(@intCast(pos_));
            try std.testing.expect(c.valid() and c.face() == f and c.level() == 1);
        }
    }
    // Malformed high-bit id must not trigger signed i64 overflow.
    _ = (Cell{ .id = 0x8000_0000_0000_0000 }).child(0);

    // Top-right corner at level 29 and 30 across all faces must not overflow i32 in center().
    const max_ij: u32 = (1 << max_level) - 1;
    for (0..6) |f| {
        const corner_leaf = Cell.fromFaceIJ(@intCast(f), max_ij, max_ij);
        const c30 = corner_leaf.center();
        const c29 = corner_leaf.parent(29).center();
        try std.testing.expect(std.math.isFinite(c30.lat) and std.math.isFinite(c30.lng));
        try std.testing.expect(std.math.isFinite(c29.lat) and std.math.isFinite(c29.lng));
    }
}
