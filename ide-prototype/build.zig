const std = @import("std");
const CrossTarget = std.zig.CrossTarget;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const native_target = b.standardTargetOptions(.{});

    const web_target_query = std.Target.Query{
        .cpu_arch = .wasm32,
        .os_tag = .wasi, // can't use freestanding cuz binaryen
        .abi = .musl,
        // https://github.com/ziglang/zig/pull/16207
        .cpu_features_add = std.Target.wasm.featureSet(&.{
            .atomics,
            .multivalue,
            .bulk_memory,
        }),
    };

    const web_target = b.resolveTargetQuery(web_target_query);

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // const web_target = CrossTarget.parse(.{
    //     .arch_os_abi = "wasm32-wasi-musl",
    //     // https://github.com/ziglang/zig/pull/16207
    //     .cpu_features = "mvp+atomics+bulk_memory",
    // }) catch unreachable;

    const dvui_dep = b.dependency("dvui", .{});
    const grappl_core_dep = b.dependency("grappl_core", .{});
    // const binaryen_dep = b.dependency("binaryen-zig", .{
    //     .target = web_target,
    //     .optimize = optimize,
    //     //.force_web = true,
    // });

    const exe = b.addExecutable(.{
        .name = "dvui-frontend",
        .root_source_file = b.path("src/main.zig"),
        .target = web_target,
        .optimize = optimize,
        .link_libc = true,
        .strip = switch (optimize) {
            .ReleaseFast, .ReleaseSmall => true,
            else => false,
        },
        .single_threaded = false,
    });

    exe.shared_memory = true;
    exe.export_memory = true;
    exe.import_memory = true;

    exe.entry = .disabled;

    //exe.root_module.addImport("binaryen", binaryen_dep.module("binaryen"));
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_web"));
    exe.root_module.addImport("WebBackend", dvui_dep.module("WebBackend"));
    exe.root_module.addImport("grappl_core", grappl_core_dep.module("grappl_core"));

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "bin" } },
    });

    const cb = b.addExecutable(.{
        .name = "cacheBuster",
        .root_source_file = dvui_dep.path("src/cacheBuster.zig"),
        .target = b.host,
    });
    const cb_run = b.addRunArtifact(cb);
    cb_run.addFileArg(b.path("index.template.html"));
    cb_run.addFileArg(b.path("WebBackend.js"));
    cb_run.addFileArg(exe.getEmittedBin());
    const output = cb_run.captureStdOut();

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(output, .{ .custom = ".." }, "index.html").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("./vite.config.ts"), .{ .custom = ".." }, "vite.config.ts").step);
    b.getInstallStep().dependOn(&install_exe.step);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
