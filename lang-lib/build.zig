const std = @import("std");
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *std.Build) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    //const binaryen_dep = b.dependency("binaryen-zig", .{});

    // TODO: reuse this in lib
    const grappl_core_mod = b.addModule("grappl_core", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    _ = grappl_core_mod;

    const lib = b.addStaticLibrary(.{
        .name = "graph-lang",
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        .pic = true,
    });
    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .name = "main-tests",
        .root_source_file = b.path("./src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // inline for (.{ &lib.root_module, &main_tests.root_module, grappl_core_mod }) |m| {
    //     m.addImport("binaryen", binaryen_dep.module("binaryen"));
    // }

    const main_tests_run = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests_run.step);

    const web_target_query = CrossTarget.parse(.{
        .arch_os_abi = "wasm32-freestanding",
        .cpu_features = "mvp+atomics+bulk_memory",
    }) catch unreachable;
    const web_target = b.resolveTargetQuery(web_target_query);

    const web_step = b.step("web", "Build for web");
    const web_lib = b.addExecutable(.{
        .name = "graph-lang",
        .root_source_file = b.path("src/c_api.zig"),
        .target = web_target,
        .optimize = optimize,
        .pic = true,
    });
    web_lib.rdynamic = true;
    web_lib.entry = .disabled;
    b.installArtifact(web_lib);

    const web_lib_install = b.addInstallArtifact(web_lib, .{});
    web_step.dependOn(&web_lib_install.step);

    const ide_json_gen_step = b.step("ide-json-gen", "Build ide-json-gen");
    const ide_json_gen = b.addExecutable(.{
        .name = "ide-json-gen",
        .root_source_file = b.path("src/ide_json_gen.zig"),
        .optimize = optimize,
        .target = target,
    });
    b.installArtifact(ide_json_gen);
    const ide_json_gen_install = b.addInstallArtifact(ide_json_gen, .{});
    ide_json_gen_step.dependOn(&ide_json_gen_install.step);
}
