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
        .backend = .raylib,
    });
    const graphl_core_dep = b.dependency("graphl", .{
        .target = target,
        .optimize = optimize,
        // FIXME: don't disable for native
        //.disable_compiler = true,
    });

    const wasm = b.addSharedLibrary(.{
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

    //exe.initial_memory = 512 * 1024 * 1024; // 512MB
    //exe.max_memory = 1 * 1024 * 1024 * 1024; // 1GB
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

    wasm.linkLibC();

    wasm.kind = .exe;
    wasm.import_symbols = true;
    wasm.rdynamic = true; // https://github.com/ziglang/zig/issues/14139
    wasm.entry = .enabled;
    wasm.wasi_exec_model = .reactor;
    //wasm.entry = .{ .symbol_name = "_initialize" };

    wasm.root_module.addImport("dvui", dvui_web_dep.module("dvui_web"));
    wasm.root_module.addImport("graphl_core", graphl_core_dep.module("graphl_core"));

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    const install_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "bin" } },
    });

    b.getInstallStep().dependOn(&install_wasm.step);

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

        const ide_unit_tests = b.addTest(.{
            .root_source_file = b.path("src/native.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .link_libc = true,
            .filters = test_filters,
            // FIXME: try to remove
            .single_threaded = true,
        });

        const run_exe_unit_tests = b.addRunArtifact(ide_unit_tests);

        ide_unit_tests.import_symbols = true;
        ide_unit_tests.rdynamic = true; // https://github.com/ziglang/zig/issues/14139
        ide_unit_tests.entry = .disabled;

        ide_unit_tests.root_module.addImport("dvui", dvui_generic_dep.module("dvui_raylib"));
        ide_unit_tests.root_module.addImport("graphl_core", graphl_core_dep.module("graphl_core"));

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_exe_unit_tests.step);

        const cgdb_step = b.step("cgdb", "run tests under cgdb");

        const cgdb_tests = b.addSystemCommand(&.{"cgdb"});
        cgdb_tests.addArtifactArg(ide_unit_tests);

        cgdb_step.dependOn(&cgdb_tests.step);
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
            // FIXME: remove!
            .single_threaded = true,
        });

        native_exe.linkLibC();

        native_exe.use_lld = false;

        const dvui_mod = dvui_generic_dep.module("dvui_raylib");

        const graphl_core_dep_with_compiler = b.dependency("graphl", .{
            .target = target,
            .optimize = optimize,
        });

        native_exe.root_module.addImport("dvui", dvui_mod);
        native_exe.root_module.addImport("graphl_core", graphl_core_dep_with_compiler.module("graphl_core"));

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
