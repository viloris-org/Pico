const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zquic — vendored pure-Zig QUIC implementation.
    const zquic_dep = b.dependency("zquic", .{
        .target = target,
        .optimize = optimize,
    });
    const zquic_mod = zquic_dep.module("zquic");

    // Shared Pico wire protocol definitions (used by both server and client).
    const clint_proto_mod = b.addModule("clint_proto", .{
        .root_source_file = b.path("clint/proto/def.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("pico", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clint_proto", .module = clint_proto_mod },
            .{ .name = "zquic", .module = zquic_mod },
        },
    });

    // Zig client library module.
    const clint_mod = b.addModule("clint", .{
        .root_source_file = b.path("clint/zig/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clint_proto", .module = clint_proto_mod },
            .{ .name = "zquic", .module = zquic_mod },
        },
    });

    // ── Server binary ──

    const exe = b.addExecutable(.{
        .name = "pico",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pico", .module = mod },
                .{ .name = "clint_proto", .module = clint_proto_mod },
                .{ .name = "zquic", .module = zquic_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const bench_exe = b.addExecutable(.{
        .name = "pico-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pico", .module = mod },
            },
        }),
    });

    const bench_step = b.step("bench", "Run SQL-path benchmarks");
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }

    // ── CLI binary ──

    const cli_exe = b.addExecutable(.{
        .name = "pico-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("clint/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clint_proto", .module = clint_proto_mod },
                .{ .name = "clint", .module = clint_mod },
                .{ .name = "zquic", .module = zquic_mod },
            },
        }),
    });

    b.installArtifact(cli_exe);

    const run_cli_step = b.step("cli", "Run Pico CLI (REPL)");
    const run_cli = b.addRunArtifact(cli_exe);
    run_cli_step.dependOn(&run_cli.step);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cli.addArgs(args);
    }

    const run_step = b.step("run", "Run Pico server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
