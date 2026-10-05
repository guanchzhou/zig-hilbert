const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const hilbert = b.addModule("hilbert", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli = b.addExecutable(.{
        .name = "zig-hilbert",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "hilbert", .module = hilbert }},
        }),
    });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.addPassthruArgs();
    b.step("run", "Run the zig-hilbert command").dependOn(&run_cli.step);

    const tests = b.addTest(.{ .root_module = hilbert });
    b.step("test", "Run the test suite").dependOn(&b.addRunArtifact(tests).step);

    const fast = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "hilbert", .module = fast }},
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    b.step("bench", "Benchmark the encoders (always ReleaseFast)").dependOn(&run_bench.step);

    const run_check = b.addRunArtifact(bench);
    run_check.addArgs(&.{ "--quick", "--check" });
    b.step("perf-check", "Fail if the measured speedups regress").dependOn(&run_check.step);
}
