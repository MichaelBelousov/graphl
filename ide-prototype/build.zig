const std = @import("std");
const CrossTarget = std.zig.CrossTarget;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const native_target = b.standardTargetOptions(.{});

    // const web_target_query = CrossTarget.parse(.{
    //     .arch_os_abi = "wasm32-wasi-musl",
    //     // https://github.com/ziglang/zig/pull/16207
    //     //.cpu_features = "mvp+atomics+bulk_memory",
    //     .cpu_features = "mvp+atomics+bulk_memory",
    // }) catch unreachable;

    const web_target_query = std.Target.Query{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding, // can't use freestanding cuz binaryen
        //.abi = .musl,
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

    const dvui_dep = b.dependency("dvui", .{});
    const grappl_core_dep = b.dependency("grappl_core", .{
        .optimize = optimize,
        .small_intrinsics = true,
    });

    const binaryen_dep = b.dependency("binaryen-zig", .{
        .target = web_target,
        .optimize = optimize,
        //.force_web = true,
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
    });

    exe.linkLibC();

    exe.import_symbols = true;
    exe.rdynamic = true; // https://github.com/ziglang/zig/issues/14139
    exe.entry = .disabled;

    exe.root_module.addImport("dvui", dvui_dep.module("dvui_web"));
    exe.root_module.addImport("WebBackend", dvui_dep.module("WebBackend"));
    exe.root_module.addImport("grappl_core", grappl_core_dep.module("grappl_core"));

    // TODO: build wasm_opt without emscripten
    const wasm_opt_emscripten_build = b.addSystemCommand(&.{
        "sh",
        "-c",
        std.fmt.allocPrint(b.allocator,
            \\cd {0s};
            \\emcmake cmake -DBUILD_FOR_BROWSER=ON -DBUILD_TESTS=OFF . > build.log 2>&1 || echo failed;
            \\emmake make > build.log 2>&1 || echo failed;
            \\echo "finished building binaryen, see $(pwd)/build.log for details"
        , .{binaryen_dep.path("binaryen").getPath(b)}) catch unreachable,
    });

    b.getInstallStep().dependOn(&wasm_opt_emscripten_build.step);

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
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(binaryen_dep.path("binaryen/bin/wasm-opt.wasm"), .bin, "wasm-opt.wasm").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(binaryen_dep.path("binaryen/bin/wasm-opt.js"), .bin, "wasm-opt.js").step);
    b.getInstallStep().dependOn(&install_exe.step);

    {
        const exe_unit_tests = b.addTest(.{
            .root_source_file = b.path("src/web.zig"),
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

    {
        const native_exe = b.addExecutable(.{
            .name = "dvui-frontend-native",
            .root_source_file = b.path("./src/native.zig"),
            .target = native_target,
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

        native_exe.root_module.addImport("dvui", dvui_dep.module("dvui_raylib"));
        native_exe.root_module.addImport("grappl_core", grappl_core_dep.module("grappl_core"));

        const native_install = b.addInstallArtifact(native_exe, .{});

        const build_native_step = b.step("native", "Build for native");
        build_native_step.dependOn(&native_install.step);
    }
}
