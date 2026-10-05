//! Splits batch work across CPU cores. On Apple Silicon this spreads the
//! batch over performance and efficiency cores; the per-point kernels stay
//! allocation-free.

const std = @import("std");

pub const max_threads = 64;

/// Below this many curve points per thread, spawning threads costs more than
/// the work, so batches stay on the calling thread.
pub const min_items_per_thread = 1 << 15;

/// Number of threads `forEachRange` will use for `n` items.
pub fn threadCount(n: usize, requested: usize, min_per_thread: usize) usize {
    const cores = if (requested != 0) requested else std.Thread.getCpuCount() catch 1;
    const by_work = @max(1, n / @max(min_per_thread, 1));
    return @max(1, @min(@min(cores, by_work), max_threads));
}

/// Calls `work(ctx, start, end)` over disjoint ranges covering `0..n`.
/// `requested` is the thread count, or 0 for one per core; each thread gets
/// at least `min_per_thread` items. If a thread cannot be spawned, its range
/// runs on the calling thread instead.
pub fn forEachRange(n: usize, requested: usize, min_per_thread: usize, ctx: anytype, comptime work: fn (@TypeOf(ctx), usize, usize) void) void {
    const count = threadCount(n, requested, min_per_thread);
    if (count == 1) return work(ctx, 0, n);
    var handles: [max_threads]?std.Thread = @splat(null);
    const per = n / count;
    var start: usize = 0;
    for (0..count - 1) |i| {
        const end = start + per;
        handles[i] = std.Thread.spawn(.{}, work, .{ ctx, start, end }) catch blk: {
            work(ctx, start, end);
            break :blk null;
        };
        start = end;
    }
    work(ctx, start, n);
    for (handles[0 .. count - 1]) |h| if (h) |t| t.join();
}

test "forEachRange covers every item exactly once" {
    const Ctx = struct {
        hits: []std.atomic.Value(u32),
        fn run(self: *const @This(), start: usize, end: usize) void {
            for (self.hits[start..end]) |*h| _ = h.fetchAdd(1, .monotonic);
        }
    };
    const n = 5 * min_items_per_thread + 17;
    const hits = try std.testing.allocator.alloc(std.atomic.Value(u32), n);
    defer std.testing.allocator.free(hits);
    for (hits) |*h| h.* = .init(0);
    const ctx: Ctx = .{ .hits = hits };
    forEachRange(n, 4, min_items_per_thread, &ctx, Ctx.run);
    for (hits) |h| try std.testing.expectEqual(@as(u32, 1), h.load(.monotonic));
}
