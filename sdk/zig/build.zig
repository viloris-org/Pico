const std = @import("std");

/// RunaDB Zig SDK — standalone package build.
///
/// In the checked-out repository, the SDK imports the shared protocol
/// definitions (`../clint/proto/def.zig`), the vendored zquic QUIC transport
/// (`../lib/zquic`), and the vendored zig-varint dependency
/// (`../zig-pkg/zig_varint-...`). The repository root `build.zig` wires the
/// same modules into the CLI and test steps; this build is for developing
/// the SDK on its own (`zig build test` inside `sdk/zig/`).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Apple platforms must link libc for zquic's compat layer; Linux stays
    // pure-Zig. Mirrors lib/zquic/build.zig (shadow mode is not used here).
    const needs_libc: bool = switch (target.result.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit => true,
        else => false,
    };

    const clint_proto_mod = b.addModule("clint_proto", .{
        .root_source_file = .{ .cwd_relative = "../../clint/proto/def.zig" },
        .target = target,
        .optimize = optimize,
    });

    const zquic_tls_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "../../lib/zquic/vendor/tls/src/root.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = needs_libc,
    });
    const zig_varint_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "../../zig-pkg/zig_varint-0.1.0-JouQHUVXAAAGN-XdMYrVEmYrzJd6zXtI7zk9bPnKYXVK/src/root.zig" },
        .target = target,
        .optimize = optimize,
    });
    const zquic_opts = b.addOptions();
    zquic_opts.addOption(bool, "verbose", false);
    zquic_opts.addOption(bool, "shadow", false);
    const zquic_mod = b.addModule("zquic", .{
        .root_source_file = .{ .cwd_relative = "../../lib/zquic/src/root.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = needs_libc,
    });
    zquic_mod.addImport("tls", zquic_tls_mod);
    zquic_mod.addImport("zig_varint", zig_varint_mod);
    zquic_mod.addOptions("build_options", zquic_opts);

    const sdk_mod = b.addModule("runadb_zig_sdk", .{
        .root_source_file = b.path("lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clint_proto", .module = clint_proto_mod },
            .{ .name = "zquic", .module = zquic_mod },
        },
    });

    const unit_tests = b.addTest(.{
        .root_module = sdk_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run SDK unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
