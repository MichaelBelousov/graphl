const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const web_target_query = std.Target.Query{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        //.abi = .musl,
        // https://github.com/ziglang/zig/pull/16207
        .cpu_features_add = std.Target.wasm.featureSet(&.{
            .atomics,
            .multivalue,
            .bulk_memory,
        }),
    };

    const web_target = b.resolveTargetQuery(web_target_query);

    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // TODO:
    const dvui_web_dep = b.dependency("dvui", .{
        .target = web_target,
        .optimize = optimize,
        .backend = .web,
    });
    const dvui_generic_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .all,
    });
    const graphl_core_dep = b.dependency("graphl", .{
        .target = target,
        .optimize = optimize,
        // FIXME: remove this old flag
        .small_intrinsics = true,
    });

    const exe = b.addExecutable(.{
        .name = "dvui-frontend",
        .root_source_file = b.path("src/web.zig"),
        .target = web_target,
        .optimize = optimize,
        .strip = switch (optimize) {
            .ReleaseFast, .ReleaseSmall => true,
            else => false,
        },
        .single_threaded = true,
    });

    const ide_module = b.addModule("ide_dvui", .{
        .root_source_file = switch (target.result.os.tag) {
            .wasi => b.path("src/web-app.zig"),
            else => b.path("src/native-app.zig"),
        },
        .target = target,
        .optimize = optimize,
    });

    switch (target.result.os.tag) {
        .wasi => ide_module.addImport("dvui", dvui_web_dep.module("dvui_web")),
        else => ide_module.addImport("dvui", dvui_generic_dep.module("dvui_raylib")),
    }
    ide_module.addImport("graphl_core", graphl_core_dep.module("graphl_core"));

    exe.linkLibC();

    exe.import_symbols = true;
    exe.rdynamic = true; // https://github.com/ziglang/zig/issues/14139
    exe.entry = .disabled;

    exe.root_module.addImport("dvui", dvui_web_dep.module("dvui_web"));
    exe.root_module.addImport("WebBackend", dvui_web_dep.module("WebBackend"));
    exe.root_module.addImport("graphl_core", graphl_core_dep.module("graphl_core"));

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "bin" } },
    });

    b.getInstallStep().dependOn(&install_exe.step);

    // FIXME: do I want this?
    // const cb = b.addExecutable(.{
    //     .name = "cacheBuster",
    //     .root_source_file = dvui_web_dep.path("src/cacheBuster.zig"),
    //     .target = b.graph.host,
    // });
    // const cb_run = b.addRunArtifact(cb);
    // cb_run.addFileArg(b.path("index.template.html"));
    // cb_run.addFileArg(b.path("WebBackend.js"));
    // cb_run.addFileArg(exe.getEmittedBin());
    // const output = cb_run.captureStdOut();
    //b.getInstallStep().dependOn(&b.addInstallFileWithDir(output, .{ .custom = ".." }, "index.html").step);

    {
        const test_filter_opt = b.option([]const u8, "test_filter", "filter-for-tests");
        const test_filters = if (test_filter_opt) |test_filter| (&[_][]const u8{test_filter}) else &[_][]const u8{};

        const exe_unit_tests = b.addTest(.{
            .root_source_file = b.path("src/native.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .link_libc = true,
            .filters = test_filters,
        });

        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

        exe_unit_tests.import_symbols = true;
        exe_unit_tests.rdynamic = true; // https://github.com/ziglang/zig/issues/14139
        exe_unit_tests.entry = .disabled;

        exe_unit_tests.root_module.addImport("dvui", dvui_generic_dep.module("dvui_raylib"));
        exe_unit_tests.root_module.addImport("graphl_core", graphl_core_dep.module("graphl_core"));

        // Similar to creating the run step earlier, this exposes a `test` step to
        // the `zig build --help` menu, providing a way for the user to request
        // running the unit tests.
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_exe_unit_tests.step);
    }

    if (target.result.os.tag != .wasi) {
        const native_exe = b.addExecutable(.{
            .name = "dvui-frontend-native",
            .root_source_file = b.path("./src/native.zig"),
            .target = target,
            .optimize = optimize,
            .strip = switch (optimize) {
                .ReleaseFast, .ReleaseSmall => true,
                else => false,
            },
        });

        native_exe.linkLibC();

        native_exe.import_symbols = true;
        native_exe.rdynamic = true; // https://github.com/ziglang/zig/issues/14139
        native_exe.entry = .disabled;

        native_exe.root_module.addImport("dvui", dvui_generic_dep.module("dvui_raylib"));
        native_exe.root_module.addImport("graphl_core", graphl_core_dep.module("graphl_core"));

        const native_install = b.addInstallArtifact(native_exe, .{});

        const build_native_step = b.step("native", "Build for native");
        build_native_step.dependOn(&native_install.step);

        if (target.result.os.tag == .windows) {
            // tinyfiledialogs needs this
            native_exe.linkSystemLibrary("comdlg32");
            native_exe.linkSystemLibrary("ole32");
        }
    }
}
