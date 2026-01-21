const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // deps
    const parser_toolkit = b.dependency("parser_toolkit", .{
        .target = target,
        .optimize = optimize,
    });

    const requezt = b.dependency("requezt", .{
        .target = target,
        .optimize = optimize,
    });

    // main module
    const graphqlz = b.addModule("graphqlz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ptk", .module = parser_toolkit.module("parser-toolkit") },
            .{ .name = "requezt", .module = requezt.module("requezt") },
        },
    });

    // graphql -> zig translation
    const g2z_step = b.step("g2z", "run GraphQL to Zig translation");
    const g2z_exe = b.addExecutable(.{
        .name = "g2z",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/g2z.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graphqlz", .module = graphqlz },
            },
        }),
    });
    b.installArtifact(g2z_exe);
    const run_g2z = b.addRunArtifact(g2z_exe);
    g2z_step.dependOn(&run_g2z.step);
    if (b.args) |args| run_g2z.addArgs(args);

    const tests = b.step("test", "run tests");
    const run_tests = b.addRunArtifact(
        b.addTest(.{
            .name = "tests",
            .root_module = graphqlz,
        }),
    );
    tests.dependOn(&run_tests.step);
}
