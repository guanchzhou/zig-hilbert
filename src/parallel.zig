//! Splits batch work across CPU cores. On Apple Silicon this spreads the
//! batch over performance and efficiency cores; the per-point kernels stay
//! allocation-free.

const std = @import("std");
const builtin = @import("builtin");

pub const max_threads = 64;

/// Below this many curve points per thread, spawning threads costs more than
/// the work, so batches stay on the calling thread.
pub const min_items_per_thread = 1 << 15;

/// Number of threads `forEachRange` will use for `n` items.
pub fn threadCount(n: usize, requested: usize, min_per_thread: usize) usize {
    if (builtin.single_threaded) return 1;
    const cores = if (requested != 0) requested else std.Thread.getCpuCount() catch 1;
    const by_work = @max(1, n / @max(min_per_thread, 1));
    return @max(1, @min(@min(cores, by_work), max_threads));
}

/// Each thread takes about this many blocks. Threads claim blocks from a
/// shared counter, so faster (performance) cores end up doing more of them
/// than slower (efficiency) cores instead of waiting for them.
const blocks_per_thread = 8;

/// Calls `work(ctx, start, end)` over disjoint ranges covering `0..n`.
/// `requested` is the thread count, or 0 for one per core; batches smaller
/// than `min_per_thread` items per thread use fewer threads. If a thread
/// cannot be spawned, the others take over its share.
pub fn forEachRange(n: usize, requested: usize, min_per_thread: usize, ctx: anytype, comptime work: fn (@TypeOf(ctx), usize, usize) void) void {
    const count = threadCount(n, requested, min_per_thread);
    if (builtin.single_threaded or count == 1) return work(ctx, 0, n);
    const Shared = struct {
        next: std.atomic.Value(usize) = .init(0),
        n: usize,
        block: usize,
        ctx: @TypeOf(ctx),

        fn loop(s: *@This()) void {
            while (true) {
                const start = s.next.fetchAdd(s.block, .monotonic);
                if (start >= s.n) return;
                work(s.ctx, start, @min(start + s.block, s.n));
            }
        }
    };
    var shared: Shared = .{ .n = n, .block = @max(1, n / (count * blocks_per_thread)), .ctx = ctx };
    var handles: [max_threads]?std.Thread = @splat(null);
    for (handles[0 .. count - 1]) |*h| {
        h.* = std.Thread.spawn(.{ .stack_size = 1 << 20 }, Shared.loop, .{&shared}) catch null;
    }
    shared.loop();
    for (handles[0 .. count - 1]) |h| if (h) |t| t.join();
}

/// Most tasks one `forEachRangeIo` call submits; the `Io` implementation
/// spreads them over its workers.
pub const max_io_tasks = 256;

/// Like `forEachRange`, but submits the ranges to `io` as a task group, so
/// the caller's `Io` implementation decides where they run.
pub fn forEachRangeIo(io: std.Io, n: usize, min_per_task: usize, ctx: anytype, comptime work: fn (@TypeOf(ctx), usize, usize) void) std.Io.Cancelable!void {
    const tasks = @max(1, @min(n / @max(min_per_task, 1), max_io_tasks));
    if (tasks == 1) return work(ctx, 0, n);
    var group: std.Io.Group = .init;
    errdefer group.cancel(io);
    const per = n / tasks;
    for (0..tasks - 1) |i| group.async(io, work, .{ ctx, i * per, (i + 1) * per });
    work(ctx, (tasks - 1) * per, n);
    try group.await(io);
}

/// Errors added by running on `Exec`: cancelation for `std.Io`, none for a
/// thread count.
pub fn ExecError(comptime Exec: type) type {
    return if (Exec == std.Io) std.Io.Cancelable else error{};
}

/// Runs `work` on `exec`: a `std.Io`, or a thread count (0 = one per core).
pub fn run(exec: anytype, n: usize, min_per_task: usize, ctx: anytype, comptime work: fn (@TypeOf(ctx), usize, usize) void) ExecError(@TypeOf(exec))!void {
    if (@TypeOf(exec) == std.Io) return forEachRangeIo(exec, n, min_per_task, ctx, work);
    forEachRange(n, exec, min_per_task, ctx, work);
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
    for (hits) |*h| try std.testing.expectEqual(@as(u32, 1), h.swap(0, .monotonic));
    try run(std.testing.io, n, 1000, &ctx, Ctx.run);
    for (hits) |*h| try std.testing.expectEqual(@as(u32, 1), h.swap(0, .monotonic));
    try run(@as(usize, 0), 10, 1000, &ctx, Ctx.run);
    for (hits[0..10]) |h| try std.testing.expectEqual(@as(u32, 1), h.load(.monotonic));
}
