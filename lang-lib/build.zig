const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const lib = b.addStaticLibrary(.{
        .name = "graph-lang",
        .root_source_file = std.build.FileSource.relative("src/main.zig"),
        .optimize = optimize,
        .target = target,
    });
    b.installArtifact(lib);
    lib.force_pic = true;

    const main_tests = b.addTest(.{
        .root_source_file = std.build.FileSource.relative("src/main.zig"),
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const web_step = b.step("web", "Build for web");
    var web_target = target;
    web_target.cpu_arch = .wasm32;
    web_target.os_tag = .freestanding;
    const web_lib = b.addExecutable(.{
        .name = "graph-lang",
        .root_source_file = std.build.FileSource.relative("src/main.zig"),
        .target = web_target,
        .optimize = optimize,
    });
    b.installArtifact(web_lib);
    const web_lib_install = b.addInstallArtifact(web_lib);
    web_step.dependOn(&web_lib_install.step);

    const ide_json_gen_step = b.step("ide-json-gen", "Build ide-json-gen");
    const ide_json_gen = b.addExecutable(.{
        .name = "ide-json-gen",
        .root_source_file = std.build.FileSource.relative("src/ide_json_gen.zig"),
        .optimize = optimize,
        .target = target,
    });
    b.installArtifact(ide_json_gen);
    const ide_json_gen_install = b.addInstallArtifact(ide_json_gen);
    ide_json_gen_step.dependOn(&ide_json_gen_install.step);
}
