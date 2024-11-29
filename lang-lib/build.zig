const std = @import("std");
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *std.Build) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const test_step = b.step("test", "Run library tests");

    //const binaryen_dep = b.dependency("binaryen-zig", .{});

    const web_target_query = CrossTarget.parse(.{
        .arch_os_abi = "wasm32-freestanding",
        .cpu_features = "mvp+atomics+bulk_memory",
    }) catch unreachable;
    const web_target = b.resolveTargetQuery(web_target_query);

    const small_intrinsics = b.option(bool, "small_intrinsics", "build intrinsic functions with ReleaseSmall for smaller output") orelse false;

    const intrinsics = b.addExecutable(.{
        .name = "grappl_intrinsics",
        .root_source_file = b.path("./src/intrinsics.zig"),
        .target = web_target,
        .optimize = if (small_intrinsics) .ReleaseSmall else optimize,
        .strip = false, // required by current usage of intrinsics
    });
    intrinsics.entry = .disabled;
    intrinsics.rdynamic = true;

    // NOTE: in the future may be able to use .getEmittedAsm to get the wasm output from zig and drop
    // wasm2wat system dep, but atm it doesn't work that way
    // FIXME: build wasm2wat as a dep
    const intrinsics_to_wat_step = b.addSystemCommand(&.{"wasm2wat"});
    intrinsics_to_wat_step.addFileArg(intrinsics.getEmittedBin());
    intrinsics_to_wat_step.addArg("-o");
    const intrinsics_wat_file = intrinsics_to_wat_step.addOutputFileArg("grappl-intrinsics.wat");
    intrinsics_to_wat_step.step.dependOn(&intrinsics.step);

    // TODO: reuse this in lib
    const grappl_core_mod = b.addModule("grappl_core", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    grappl_core_mod.addAnonymousImport("grappl_intrinsics", .{
        .root_source_file = intrinsics_wat_file,
        .optimize = optimize,
        .target = web_target,
    });

    // don't include
    const disable_compiler = b.option(bool, "disable_compiler", "don't include code for display-only scenarios, e.g. don't include the compiler") orelse false;
    const lib_opts = b.addOptions();
    lib_opts.addOption(bool, "disable_compiler", disable_compiler);

    const lib = b.addStaticLibrary(.{
        .name = "graph-lang",
        .root_source_file = null,
        .optimize = optimize,
        .target = target,
        .pic = true,
    });
    lib.root_module.addOptions("build_opts", lib_opts);
    lib.root_module.addImport("core", grappl_core_mod);
    lib.step.dependOn(&intrinsics_to_wat_step.step);

    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .name = "main-tests",
        .root_source_file = b.path("./src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_tests.step.dependOn(&intrinsics_to_wat_step.step);
    main_tests.root_module.addAnonymousImport("grappl_intrinsics", .{
        .root_source_file = intrinsics_wat_file,
        .optimize = optimize,
        .target = web_target,
    });

    // FIXME: rename to graphltc
    const graphltc_tool = b.step("graphltc", "build the text version of the compiler");
    const graphltc_exe = b.addExecutable(.{
        .name = "graphltc",
        .root_source_file = b.path("./src/graphltc.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphltc_exe.step.dependOn(&intrinsics_to_wat_step.step);
    graphltc_exe.root_module.addAnonymousImport("grappl_intrinsics", .{
        .root_source_file = intrinsics_wat_file,
        .optimize = optimize,
        .target = web_target,
    });
    b.installArtifact(graphltc_exe);
    const graphltc_install = b.addInstallArtifact(graphltc_exe, .{});
    graphltc_tool.dependOn(&graphltc_install.step);

    // inline for (.{ &lib.root_module, &main_tests.root_module, grappl_core_mod }) |m| {
    //     m.addImport("binaryen", binaryen_dep.module("binaryen"));
    // }

    const main_tests_run = b.addRunArtifact(main_tests);

    test_step.dependOn(&main_tests_run.step);

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
