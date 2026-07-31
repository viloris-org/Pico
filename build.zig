const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared RunaDB wire protocol definitions (used by both server and client).
    const clint_proto_mod = b.addModule("clint_proto", .{
        .root_source_file = b.path("clint/proto/def.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("runadb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clint_proto", .module = clint_proto_mod },
        },
    });

    // Zig client library module.
    const clint_mod = b.addModule("clint", .{
        .root_source_file = b.path("clint/zig/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clint_proto", .module = clint_proto_mod },
        },
    });

    // ── Server binary ──

    const exe = b.addExecutable(.{
        .name = "runa",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runadb", .module = mod },
                .{ .name = "clint_proto", .module = clint_proto_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const wal_bench_exe = b.addExecutable(.{
        .name = "runa-wal-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wal_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runadb", .module = mod },
            },
        }),
    });
    const wal_bench_step = b.step("wal-bench", "Run WAL microbenchmarks");
    const run_wal_bench = b.addRunArtifact(wal_bench_exe);
    wal_bench_step.dependOn(&run_wal_bench.step);

    // ── CLI binary ──

    const cli_exe = b.addExecutable(.{
        .name = "runa-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("clint/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clint_proto", .module = clint_proto_mod },
                .{ .name = "clint", .module = clint_mod },
            },
        }),
    });

    b.installArtifact(cli_exe);

    const run_cli_step = b.step("cli", "Run RunaDB CLI (REPL)");
    const run_cli = b.addRunArtifact(cli_exe);
    run_cli_step.dependOn(&run_cli.step);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cli.addArgs(args);
    }

    const run_step = b.step("run", "Run RunaDB server");
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

    const clint_tests = b.addTest(.{
        .root_module = clint_mod,
    });
    const run_clint_tests = b.addRunArtifact(clint_tests);

    const clint_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("clint/zig/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "clint", .module = clint_mod },
            },
        }),
    });
    const run_clint_integration_tests = b.addRunArtifact(clint_integration_tests);
    run_clint_integration_tests.step.dependOn(b.getInstallStep());
    run_clint_integration_tests.setEnvironmentVariable(
        "RUNA_TEST_SERVER",
        b.getInstallPath(.bin, "runa"),
    );

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_clint_tests.step);
    test_step.dependOn(&run_clint_integration_tests.step);
}
