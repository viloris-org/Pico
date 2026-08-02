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

    // ── zquic (vendored pure-Zig QUIC, ADR-0015) ──
    // Mirrors lib/zquic/build.zig: the vendored TLS module, the vendored
    // zig_varint package, and the verbose/shadow build options. Apple
    // platforms link libc; Linux stays pure-Zig (shadow mode unused here).
    const zquic_needs_libc: bool = switch (target.result.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit => true,
        else => false,
    };
    const zquic_tls_mod = b.createModule(.{
        .root_source_file = b.path("lib/zquic/vendor/tls/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = zquic_needs_libc,
    });
    const zig_varint_mod = b.createModule(.{
        .root_source_file = b.path("zig-pkg/zig_varint-0.1.0-JouQHUVXAAAGN-XdMYrVEmYrzJd6zXtI7zk9bPnKYXVK/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zquic_opts = b.addOptions();
    zquic_opts.addOption(bool, "verbose", false);
    zquic_opts.addOption(bool, "shadow", false);
    const zquic_mod = b.addModule("zquic", .{
        .root_source_file = b.path("lib/zquic/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = zquic_needs_libc,
    });
    zquic_mod.addImport("tls", zquic_tls_mod);
    zquic_mod.addImport("zig_varint", zig_varint_mod);
    zquic_mod.addOptions("build_options", zquic_opts);

    // The server-side QUIC listener (src/net/quic.zig, ADR-0015/0023) lives in
    // the `runadb` module and imports the vendored zquic stack.
    mod.addImport("zquic", zquic_mod);

    // Zig SDK module (official SDK package, ADR-0023).
    const sdk_zig_mod = b.addModule("sdk_zig", .{
        .root_source_file = b.path("sdk/zig/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clint_proto", .module = clint_proto_mod },
            .{ .name = "zquic", .module = zquic_mod },
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
                .{ .name = "sdk_zig", .module = sdk_zig_mod },
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
        .root_module = sdk_zig_mod,
    });
    const run_clint_tests = b.addRunArtifact(clint_tests);

    const clint_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("sdk/zig/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sdk_zig", .module = sdk_zig_mod },
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
