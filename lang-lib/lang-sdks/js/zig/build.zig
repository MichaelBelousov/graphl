const std = @import("std");
const CrossTarget = std.zig.CrossTarget;
const cfg = @import("./build-cfg.zig");

// https://github.com/chung-leong/zigar/wiki/Custom-build-file
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addSharedLibrary(.{
        .name = cfg.module_name,
        .root_source_file = .{ .cwd_relative = cfg.stub_path },
        .target = target,
        .optimize = optimize,
    });

    const graphl = b.dependency("graphl", .{ .target = target, .optimize = optimize });

    const imports = .{
        .{ .name = "graphl", .module = graphl.module("graphl") },
    };

    const mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = cfg.module_path },
        .imports = &imports,
    });
    mod.addIncludePath(.{ .cwd_relative = cfg.module_dir });
    lib.root_module.addImport("module", mod);
    if (cfg.is_wasm) {
        // WASM needs to be compiled as exe
        lib.kind = .exe;
        lib.linkage = .static;
        lib.entry = .disabled;
        lib.rdynamic = true;
        lib.wasi_exec_model = .reactor;
    }
    if (cfg.use_libc) {
        lib.linkLibC();
    }
    const wf = switch (@hasDecl(std.Build, "addUpdateSourceFiles")) {
        true => b.addUpdateSourceFiles(),
        false => b.addWriteFiles(),
    };
    wf.addCopyFileToSource(lib.getEmittedBin(), cfg.output_path);
    wf.step.dependOn(&lib.step);
    b.getInstallStep().dependOn(&wf.step);

    try buildTests(b, target, optimize);
}

pub fn buildTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const tests = b.addTest(.{
        .root_source_file = b.path("./js.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "run tests");
    test_step.dependOn(&run_tests.step);
}
