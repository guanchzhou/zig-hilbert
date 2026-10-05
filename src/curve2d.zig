//! 2D Hilbert curve driven by tables generated at compile time.
//!
//! The curve orientation is the classic one: it starts at (0, 0) and ends at
//! (2^bits - 1, 0), and matches `reference.encode2` bit for bit.
//!
//! Each level of the curve leaves the remaining lower bits in one of four
//! orientations: identity, transposed, complemented, or both. Transposition
//! and complement commute and are involutions, so the orientation is two bits
//! (`swap`, `flip`). A table indexed by orientation and `chunk` bits of x and
//! y returns `2 * chunk` index bits and the next orientation, so one load
//! replaces `chunk` iterations of the bit-serial loop.

const std = @import("std");

pub const max_bits = 32;

/// Chunk width used by the public functions, the fastest width measured by
/// `zig build bench`. Its 32 KiB encode table fits the L1 data cache of both
/// performance and efficiency cores on Apple Silicon.
pub const default_chunk = 6;

pub const Point = struct { x: u32, y: u32 };

pub const Error = error{ OrderOutOfRange, CoordinateOutOfRange, IndexOutOfRange };

const Step = struct { digit: u2, state: u2 };

fn encodeStep(state: u2, bx: u1, by: u1) Step {
    const swap: u1 = @truncate(state);
    const flip: u1 = @truncate(state >> 1);
    const rx = (if (swap == 1) by else bx) ^ flip;
    const ry = (if (swap == 1) bx else by) ^ flip;
    const toggle = ~ry;
    return .{
        .digit = (@as(u2, rx) << 1) | @as(u2, rx ^ ry),
        .state = @as(u2, swap ^ toggle) | (@as(u2, flip ^ (toggle & rx)) << 1),
    };
}

fn decodeStep(state: u2, digit: u2) struct { bx: u1, by: u1, state: u2 } {
    const swap: u1 = @truncate(state);
    const flip: u1 = @truncate(state >> 1);
    const rx: u1 = @truncate(digit >> 1);
    const ry: u1 = @truncate(digit ^ rx);
    const a = rx ^ flip;
    const b = ry ^ flip;
    const toggle = ~ry;
    return .{
        .bx = if (swap == 1) b else a,
        .by = if (swap == 1) a else b,
        .state = @as(u2, swap ^ toggle) | (@as(u2, flip ^ (toggle & rx)) << 1),
    };
}

/// Encode and decode tables for `chunk` bit levels per lookup. Public for
/// the benchmark and tests; the layout may change between versions.
/// Encode index: `state << 2c | x_chunk << c | y_chunk`, value: `state' << 2c | digits`.
/// Decode index: `state << 2c | digits`, value: `state' << 2c | x_chunk << c | y_chunk`.
pub fn Tables(comptime chunk: u4) type {
    if (chunk < 1 or chunk > 6) @compileError("chunk must be 1..6");
    return struct {
        pub const width = chunk;
        pub const entries = @as(usize, 4) << (2 * chunk);
        pub const Entry = if (2 * @as(u32, chunk) + 2 <= 8) u8 else u16;
        pub const bytes = entries * @sizeOf(Entry);

        pub const encode: [entries]Entry = build(true);
        pub const decode: [entries]Entry = build(false);

        fn build(comptime forward: bool) [entries]Entry {
            @setEvalBranchQuota(20_000_000);
            if (chunk >= 2) return compose(forward);
            var table: [entries]Entry = undefined;
            const c: u5 = chunk;
            const low: u32 = (@as(u32, 1) << (2 * c)) - 1;
            for (0..entries) |i| {
                var state: u2 = @intCast(i >> (2 * c));
                const payload: u32 = @intCast(i & low);
                var out: u32 = 0;
                var level: u5 = c;
                while (level > 0) {
                    level -= 1;
                    if (forward) {
                        const bx: u1 = @truncate(payload >> (c + level));
                        const by: u1 = @truncate(payload >> level);
                        const s = encodeStep(state, bx, by);
                        out = (out << 2) | s.digit;
                        state = s.state;
                    } else {
                        const digit: u2 = @truncate(payload >> (2 * level));
                        const s = decodeStep(state, digit);
                        out |= (@as(u32, s.bx) << (c + level)) | (@as(u32, s.by) << level);
                        state = s.state;
                    }
                }
                table[i] = @intCast(out | (@as(u32, state) << (2 * c)));
            }
            return table;
        }

        /// Builds this table from the tables for the high `h` and low `l`
        /// levels (`h + l = chunk`): two lookups per entry instead of
        /// `chunk` steps, which keeps compile time down.
        fn compose(comptime forward: bool) [entries]Entry {
            @setEvalBranchQuota(20_000_000);
            const h: u4 = chunk / 2;
            const l: u4 = chunk - h;
            const H = Tables(h);
            const L = Tables(l);
            const c: u5 = chunk;
            const hm: u32 = (@as(u32, 1) << h) - 1;
            const lm: u32 = (@as(u32, 1) << l) - 1;
            var table: [entries]Entry = undefined;
            for (0..entries) |i_| {
                const i: u32 = @intCast(i_);
                const state = i >> (2 * c);
                if (forward) {
                    const xs = (i >> c) & ((@as(u32, 1) << c) - 1);
                    const ys = i & ((@as(u32, 1) << c) - 1);
                    const e1: u32 = H.encode[(state << (2 * h)) | ((xs >> l) << h) | (ys >> l)];
                    const e2: u32 = L.encode[((e1 >> (2 * h)) << (2 * l)) | ((xs & lm) << l) | (ys & lm)];
                    const d1 = e1 & ((@as(u32, 1) << (2 * h)) - 1);
                    const d2 = e2 & ((@as(u32, 1) << (2 * l)) - 1);
                    table[i] = @intCast(((e2 >> (2 * l)) << (2 * c)) | (d1 << (2 * l)) | d2);
                } else {
                    const digits = i & ((@as(u32, 1) << (2 * c)) - 1);
                    const e1: u32 = H.decode[(state << (2 * h)) | (digits >> (2 * l))];
                    const e2: u32 = L.decode[((e1 >> (2 * h)) << (2 * l)) | (digits & ((@as(u32, 1) << (2 * l)) - 1))];
                    const x = (((e1 >> h) & hm) << l) | ((e2 >> l) & lm);
                    const y = ((e1 & hm) << l) | (e2 & lm);
                    table[i] = @intCast(((e2 >> (2 * l)) << (2 * c)) | (x << c) | y);
                }
            }
            return table;
        }
    };
}

/// Levels above `bits` are padded with zero coordinate bits. Every padded
/// level emits digit 0 and transposes, so starting transposed when the
/// padding count is odd leaves the real levels in the identity orientation.
inline fn initialState(chunks: u32, chunk: u32, bits: u32) u32 {
    return (chunks * chunk - bits) & 1;
}

/// Hilbert index of `(x, y)` with `chunk` bit levels per table lookup.
/// Precondition: `x < 2^bits` and `y < 2^bits`; higher bits are ignored.
pub inline fn encodeWith(comptime chunk: u4, comptime bits: u6, x: u32, y: u32) u64 {
    comptime std.debug.assert(bits >= 1 and bits <= max_bits);
    const T = Tables(chunk);
    const chunks = (@as(u32, bits) + chunk - 1) / chunk;
    const mask: u64 = (@as(u64, 1) << chunk) - 1;
    const keep: u64 = (@as(u64, 1) << bits) - 1;
    const px: u64 = x & keep;
    const py: u64 = y & keep;
    var state: u32 = comptime initialState(chunks, chunk, bits);
    var index: u64 = 0;
    inline for (0..chunks) |k| {
        const shift: u6 = @intCast((chunks - 1 - k) * chunk);
        const slot = (state << (2 * chunk)) | @as(u32, @intCast((((px >> shift) & mask) << chunk) | ((py >> shift) & mask)));
        const entry: u32 = T.encode[slot];
        index = (index << (2 * chunk)) | (entry & ((@as(u32, 1) << (2 * chunk)) - 1));
        state = entry >> (2 * chunk);
    }
    return index;
}

/// Inverse of `encodeWith`. Precondition: `index < 4^bits`.
pub inline fn decodeWith(comptime chunk: u4, comptime bits: u6, index: u64) Point {
    comptime std.debug.assert(bits >= 1 and bits <= max_bits);
    const T = Tables(chunk);
    const chunks = (@as(u32, bits) + chunk - 1) / chunk;
    const digit_mask: u64 = (@as(u64, 1) << (2 * chunk)) - 1;
    const coord_mask: u32 = (@as(u32, 1) << chunk) - 1;
    const h: u64 = if (bits == 32) index else index & ((@as(u64, 1) << (2 * bits)) - 1);
    var state: u32 = comptime initialState(chunks, chunk, bits);
    var x: u64 = 0;
    var y: u64 = 0;
    inline for (0..chunks) |k| {
        const shift: u6 = @intCast(2 * (chunks - 1 - k) * chunk);
        const slot = (state << (2 * chunk)) | @as(u32, @intCast((h >> shift) & digit_mask));
        const entry: u32 = T.decode[slot];
        x = (x << chunk) | ((entry >> chunk) & coord_mask);
        y = (y << chunk) | (entry & coord_mask);
        state = entry >> (2 * chunk);
    }
    return .{ .x = @truncate(x), .y = @truncate(y) };
}

/// Hilbert index of `(x, y)` on a `2^bits` grid. `bits` is comptime so the
/// lookups unroll. Precondition: `x < 2^bits` and `y < 2^bits`.
pub inline fn encode(comptime bits: u6, x: u32, y: u32) u64 {
    return encodeWith(default_chunk, bits, x, y);
}

/// Inverse of `encode`. Precondition: `index < 4^bits`.
pub inline fn decode(comptime bits: u6, index: u64) Point {
    return decodeWith(default_chunk, bits, index);
}

/// Runtime-order encode that validates its arguments.
pub fn encodeChecked(bits: u6, x: u32, y: u32) Error!u64 {
    if (bits < 1 or bits > max_bits) return error.OrderOutOfRange;
    if (bits < 32 and (x >> @intCast(bits) != 0 or y >> @intCast(bits) != 0)) return error.CoordinateOutOfRange;
    return switch (bits) {
        inline 1...max_bits => |b| encode(b, x, y),
        else => unreachable,
    };
}

/// Runtime-order decode that validates its arguments.
pub fn decodeChecked(bits: u6, index: u64) Error!Point {
    if (bits < 1 or bits > max_bits) return error.OrderOutOfRange;
    if (bits < 32 and index >> @intCast(2 * @as(u7, bits)) != 0) return error.IndexOutOfRange;
    return switch (bits) {
        inline 1...max_bits => |b| decode(b, index),
        else => unreachable,
    };
}

/// Experimental: branch-free per-bit encoder over `lanes` points at once.
/// It maps to NEON on Apple Silicon but is slower than `encode`; it is kept
/// for the benchmark comparison and may change or be removed.
pub inline fn encodeLanes(comptime lanes: comptime_int, comptime bits: u6, x: @Vector(lanes, u32), y: @Vector(lanes, u32)) @Vector(lanes, u64) {
    const V32 = @Vector(lanes, u32);
    const one: V32 = @splat(1);
    const shl1: @Vector(lanes, u5) = @splat(1);
    const shl2: @Vector(lanes, u6) = @splat(2);
    const keep: V32 = @splat(@intCast((@as(u64, 1) << bits) - 1));
    const px = x & keep;
    const py = y & keep;
    var swap: V32 = @splat(0);
    var flip: V32 = @splat(0);
    var index: @Vector(lanes, u64) = @splat(0);
    inline for (0..bits) |k| {
        const shift: @Vector(lanes, u5) = @splat(@intCast(bits - 1 - k));
        const bx = (px >> shift) & one;
        const by = (py >> shift) & one;
        const sel = swap == one;
        const rx = @select(u32, sel, by, bx) ^ flip;
        const ry = @select(u32, sel, bx, by) ^ flip;
        const digit = (rx << shl1) | (rx ^ ry);
        index = (index << shl2) | @as(@Vector(lanes, u64), @intCast(digit));
        const toggle = ry ^ one;
        swap ^= toggle;
        flip ^= toggle & rx;
    }
    return index;
}

test "vector encoder matches the reference curve" {
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    inline for (.{ 5, 16, 32 }) |bits| {
        for (0..512) |_| {
            var xs: [8]u32 = undefined;
            var ys: [8]u32 = undefined;
            for (&xs, &ys) |*x, *y| {
                x.* = r.int(u32) >> (32 - bits);
                y.* = r.int(u32) >> (32 - bits);
            }
            const got: [8]u64 = encodeLanes(8, bits, xs, ys);
            for (xs, ys, got) |x, y, h| try std.testing.expectEqual(@import("reference.zig").encode2(bits, x, y), h);
        }
    }
}

test "tables match the reference curve exhaustively up to order 8" {
    inline for (1..7) |chunk| {
        inline for (1..9) |bits| {
            const n: u32 = @as(u32, 1) << bits;
            var y: u32 = 0;
            while (y < n) : (y += 1) {
                var x: u32 = 0;
                while (x < n) : (x += 1) {
                    const want = @import("reference.zig").encode2(bits, x, y);
                    const got = encodeWith(chunk, bits, x, y);
                    try std.testing.expectEqual(want, got);
                    const p = decodeWith(chunk, bits, got);
                    try std.testing.expectEqual(x, p.x);
                    try std.testing.expectEqual(y, p.y);
                }
            }
        }
    }
}
