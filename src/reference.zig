//! Bit-serial reference implementations. They are slow on purpose: every
//! other encoder in the package is tested against these.

/// Hilbert index of `(x, y)` on a `2^bits` by `2^bits` grid, processing one
/// bit level per iteration (the classic `xy2d` formulation).
pub fn encode2(bits: u6, x: u32, y: u32) u64 {
    const n: u64 = @as(u64, 1) << bits;
    var px: u64 = x;
    var py: u64 = y;
    var d: u64 = 0;
    var s: u64 = n >> 1;
    while (s > 0) : (s >>= 1) {
        const rx: u64 = @intFromBool(px & s != 0);
        const ry: u64 = @intFromBool(py & s != 0);
        d += s * s * ((3 * rx) ^ ry);
        if (ry == 0) {
            if (rx == 1) {
                px = n - 1 - px;
                py = n - 1 - py;
            }
            const t = px;
            px = py;
            py = t;
        }
    }
    return d;
}

/// Inverse of `encode2`.
pub fn decode2(bits: u6, index: u64) [2]u32 {
    const n: u64 = @as(u64, 1) << bits;
    var px: u64 = 0;
    var py: u64 = 0;
    var t = index;
    var s: u64 = 1;
    while (s < n) : (s <<= 1) {
        const rx: u64 = 1 & (t >> 1);
        const ry: u64 = 1 & (t ^ rx);
        if (ry == 0) {
            if (rx == 1) {
                px = s - 1 - px;
                py = s - 1 - py;
            }
            const tmp = px;
            px = py;
            py = tmp;
        }
        px += s * rx;
        py += s * ry;
        t >>= 2;
    }
    return .{ @intCast(px), @intCast(py) };
}
