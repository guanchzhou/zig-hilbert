const std = @import("std");
const cli_cases = @import("test/cli_cases.zig");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const hilbert = b.addModule("hilbert", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    const cli = b.addExecutable(.{
        .name = "zig-hilbert",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hilbert", .module = hilbert },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.addPassthruArgs();
    b.step("run", "Run the zig-hilbert command").dependOn(&run_cli.step);

    const tests = b.addTest(.{ .root_module = hilbert });
    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    b.step("test-build", "Compile the tests without running them (for cross targets)").dependOn(&tests.step);

    const test_cli = b.step("test-cli", "Run the command-line tests");
    for (cli_cases.cases) |c| {
        const run = b.addRunArtifact(cli);
        run.setName(b.fmt("zig-hilbert {s}", .{c.name}));
        run.addArgs(c.args);
        run.setStdIn(if (c.stdin) |s| .{ .bytes = s } else .none);
        if (c.stdout) |s| run.expectStdOutEqual(s);
        if (c.stderr) |s| run.expectStdErrMatch(s);
        run.expectExitCode(c.exit);
        test_cli.dependOn(&run.step);
    }
    if (@import("builtin").os.tag != .windows) {
        const shared = b.addSystemCommand(&.{ "sh", "-c", "{ \"$0\" version; \"$0\" version; } > \"$1\" && cat \"$1\"" });
        shared.setName("zig-hilbert: two runs appending to one stdout file");
        shared.addArtifactArg(cli);
        _ = shared.addOutputFileArg("stdout.txt");
        shared.expectStdOutEqual(b.fmt("zig-hilbert {0s}\nzig-hilbert {0s}\n", .{zon.version}));
        test_cli.dependOn(&shared.step);
    }
    test_step.dependOn(test_cli);

    const golden = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/golden.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "hilbert", .module = hilbert }},
    }) });
    test_step.dependOn(&b.addRunArtifact(golden).step);

    for ([_][]const u8{ "curves", "markers", "s2" }) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "hilbert", .module = hilbert }},
            }),
        });
        const run = b.addRunArtifact(example);
        run.expectExitCode(0);
        test_step.dependOn(&run.step);
    }

    const gen = b.addExecutable(.{
        .name = "gen-markers",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/gen_markers.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "hilbert", .module = hilbert }},
        }),
    });
    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(b.addRunArtifact(gen).captureStdOut(.{}), "test/markers.jsonl");
    b.step("golden", "Regenerate test/markers.jsonl (marker format changes only)").dependOn(&update.step);

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

    const docs_lib = b.addLibrary(.{ .name = "hilbert", .root_module = hilbert });
    const docs = b.addInstallDirectory(.{ .source_dir = docs_lib.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" });
    b.step("docs", "Generate API documentation into zig-out/docs").dependOn(&docs.step);

    const run_check = b.addRunArtifact(bench);
    run_check.addArgs(&.{ "--quick", "--check" });
    b.step("perf-check", "Fail if the measured speedups regress").dependOn(&run_check.step);
}
