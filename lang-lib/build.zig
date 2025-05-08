const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const test_step = b.step("test", "Run library tests");

    const binaryen_dep = b.lazyDependency("binaryen-zig", .{
        .optimize = optimize,
        .target = target,
        //.relooper_debug = optimize == .Debug,
        // FIXME: using single_threaded breaks native tests somehow
        // FIXME: somehow the following check doesn't work
        //.single_threaded = target.result.cpu.arch.isWasm(),
        .single_threaded = true,
    });

    //const bytebox_dep = b.dependency("bytebox", .{});

    const intrinsics_target_query = std.Target.Query{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        // https://github.com/ziglang/zig/pull/16207
        .cpu_features_add = std.Target.wasm.featureSet(&.{
            .atomics,
            .multivalue,
            .bulk_memory,
        }),
    };
    const intrinsics_target = b.resolveTargetQuery(intrinsics_target_query);

    // TODO: make this false in some cases
    const small_intrinsics = b.option(bool, "small_intrinsics", "build intrinsic functions with ReleaseSmall for smaller output") orelse true;

    const build_string_intrinsics_step = b.addSystemCommand(&.{
        "wasm-tools",
        "parse",
    });
    build_string_intrinsics_step.addFileArg(b.path("./src/intrinsics/string/impl.wat"));
    build_string_intrinsics_step.addArg("-o");
    const build_string_intrinsics_wasm = build_string_intrinsics_step.addOutputFileArg("string_intrinsics.wasm");

    const intrinsics = .{
        .vec3 = b.addExecutable(.{
            .name = "graphl_intrinsics_vec3",
            .root_source_file = b.path("./src/intrinsics/vec3/impl.zig"),
            .target = intrinsics_target,
            .optimize = if (small_intrinsics) .ReleaseSmall else optimize,
            // the compiler must choose whether to strip or not
            .strip = false,
            .single_threaded = true,
            .pic = true,
            .unwind_tables = .none,
            .error_tracing = false,
            .code_model = .small,
        }),
        .string = .{
            .bin = build_string_intrinsics_wasm,
        },
    };

    intrinsics.vec3.entry = .disabled;
    intrinsics.vec3.rdynamic = true; // export everything

    // don't include
    const disable_compiler = b.option(bool, "disable_compiler", "don't include code for display-only scenarios, e.g. don't include the compiler") orelse false;
    const lib_opts = b.addOptions();
    lib_opts.addOption(bool, "disable_compiler", disable_compiler);

    // TODO: reuse this in lib
    const graphl_core_mod = b.addModule("graphl_core", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .single_threaded = true,
    });

    // TODO: get a working test VM again
    //graphl_core_mod.addImport("bytebox", bytebox_dep.module("bytebox"));

    const lib = b.addStaticLibrary(.{
        .name = "graph-lang",
        .root_module = graphl_core_mod,
        .pic = true,
    });

    b.installArtifact(lib);

    const test_filter_opt = b.option([]const u8, "test_filter", "filter-for-tests");
    const test_filters = if (test_filter_opt) |test_filter| (&[_][]const u8{test_filter}) else &[_][]const u8{};

    const main_tests = b.addTest(.{
        .name = "main-tests",
        .root_source_file = b.path("./src/main.zig"),
        .target = target,
        .optimize = optimize,
        .filters = test_filters,
    });
    //main_tests.root_module.addImport("bytebox", bytebox_dep.module("bytebox"));

    // FIXME: rename to graphltc
    const graphltc_tool = b.step("graphltc", "build the text version of the compiler");
    const graphltc_exe = b.addExecutable(.{
        .name = "graphltc",
        .root_source_file = b.path("./src/graphltc.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    b.installArtifact(graphltc_exe);
    const graphltc_install = b.addInstallArtifact(graphltc_exe, .{});
    graphltc_tool.dependOn(&graphltc_install.step);

    inline for (.{
        lib,
        main_tests,
        graphltc_exe,
    }) |c| {
        c.step.dependOn(&intrinsics.vec3.step);
    }

    inline for (.{
        &lib.root_module,
        &main_tests.root_module,
        graphl_core_mod,
        &graphltc_exe.root_module,
    }) |m| {
        if (!disable_compiler) {
            if (binaryen_dep) |d| {
                m.*.addImport("binaryen", d.module("binaryen"));
            }
        }
        m.*.addOptions("build_opts", lib_opts);
        m.*.addAnonymousImport("graphl_intrinsics_vec3", .{
            .root_source_file = intrinsics.vec3.getEmittedBin(),
            .optimize = optimize,
            .target = intrinsics_target,
        });
        m.*.addAnonymousImport("graphl_intrinsics_string", .{
            .root_source_file = intrinsics.string.bin,
            .optimize = optimize,
            .target = intrinsics_target,
        });
    }

    const main_tests_run = b.addRunArtifact(main_tests);

    test_step.dependOn(&main_tests_run.step);

    const cgdb_step = b.step("cgdb", "run tests under cgdb");

    const cgdb_tests = b.addSystemCommand(&.{"cgdb"});
    cgdb_tests.addArtifactArg(main_tests);

    cgdb_step.dependOn(&cgdb_tests.step);

    // const web_step = b.step("web", "Build for web");
    // const web_lib = b.addExecutable(.{
    //     .name = "graph-lang",
    //     .root_source_file = b.path("src/c_api.zig"),
    //     .target = web_target,
    //     .optimize = optimize,
    //     .pic = true,
    // });
    // web_lib.rdynamic = true;
    // web_lib.entry = .disabled;
    // b.installArtifact(web_lib);

    // const web_lib_install = b.addInstallArtifact(web_lib, .{});
    // web_step.dependOn(&web_lib_install.step);
}
