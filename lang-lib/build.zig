const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const test_step = b.step("test", "Run library tests");

    const binaryen_dep = b.dependency("binaryen-zig", .{});
    //const bytebox_dep = b.dependency("bytebox", .{});

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

    const wabt = addWat2Wasm(b, target, optimize);
    const wasm2wat = wabt.wasm2wat;

    // FIXME: make the default true for tests
    const small_intrinsics = b.option(bool, "small_intrinsics", "build intrinsic functions with ReleaseSmall for smaller output") orelse false;

    const intrinsics = b.addExecutable(.{
        .name = "graphl_intrinsics",
        .root_source_file = b.path("./src/intrinsics.zig"),
        .target = web_target,
        .optimize = if (small_intrinsics) .ReleaseSmall else optimize,
        .strip = false, // required by current usage of intrinsics
    });
    intrinsics.entry = .disabled;
    intrinsics.rdynamic = true;

    // NOTE: in the future may be able to use .getEmittedAsm to get the wasm output from zig and drop
    // wasm2wat system dep, but atm it doesn't work that way
    const intrinsics_to_wat_step = b.addRunArtifact(wasm2wat);
    intrinsics_to_wat_step.addFileArg(intrinsics.getEmittedBin());
    intrinsics_to_wat_step.addArg("-o");
    const intrinsics_wat_file = intrinsics_to_wat_step.addOutputFileArg("graphl-intrinsics.wat");
    intrinsics_to_wat_step.step.dependOn(&intrinsics.step);

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
    });
    graphl_core_mod.addOptions("build_opts", lib_opts);

    //graphl_core_mod.addImport("bytebox", bytebox_dep.module("bytebox"));

    const lib = b.addStaticLibrary(.{
        .name = "graph-lang",
        .root_module = null,
        .root_source_file = null,
        .optimize = optimize,
        .target = target,
        .pic = true,
    });
    lib.root_module.addImport("core", graphl_core_mod);
    lib.step.dependOn(&intrinsics_to_wat_step.step);

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
    main_tests.step.dependOn(&intrinsics_to_wat_step.step);
    //main_tests.root_module.addImport("bytebox", bytebox_dep.module("bytebox"));
    main_tests.root_module.addImport("binaryen", binaryen_dep.module("binaryen"));
    main_tests.root_module.addOptions("build_opts", lib_opts);

    // FIXME: rename to graphltc
    const graphltc_tool = b.step("graphltc", "build the text version of the compiler");
    const graphltc_exe = b.addExecutable(.{
        .name = "graphltc",
        .root_source_file = b.path("./src/graphltc.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphltc_exe.step.dependOn(&intrinsics_to_wat_step.step);
    b.installArtifact(graphltc_exe);
    const graphltc_install = b.addInstallArtifact(graphltc_exe, .{});
    graphltc_tool.dependOn(&graphltc_install.step);

    inline for (.{
        &lib.root_module,
        &main_tests.root_module,
        graphl_core_mod,
        &graphltc_exe.root_module,
    }) |m| {
        m.*.addImport("binaryen", binaryen_dep.module("binaryen"));
        m.*.addAnonymousImport("graphl_intrinsics", .{
            .root_source_file = intrinsics_wat_file,
            .optimize = optimize,
            .target = web_target,
        });
    }

    const main_tests_run = b.addRunArtifact(main_tests);

    test_step.dependOn(&main_tests_run.step);

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

const WabtResult = struct {
    wasm2wat: *std.Build.Step.Compile,
    wat2wasm: *std.Build.Step.Compile,
};

fn addWat2Wasm(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) WabtResult {
    const wabt_dep = b.dependency("wabt", .{});

    const wabt_config_h = b.addConfigHeader(.{
        .style = .{ .cmake = wabt_dep.path("src/config.h.in") },
        .include_path = "wabt/config.h",
    }, .{
        .WABT_VERSION_STRING = "1.0.34",
        .HAVE_SNPRINTF = 1,
        .HAVE_SSIZE_T = 1,
        .HAVE_STRCASECMP = 1,
        .COMPILER_IS_CLANG = 1,
        .SIZEOF_SIZE_T = @sizeOf(usize),
    });

    const wabt_lib = b.addStaticLibrary(.{
        .name = "wabt",
        .target = target,
        .optimize = optimize,
    });
    wabt_lib.addConfigHeader(wabt_config_h);
    wabt_lib.addIncludePath(wabt_dep.path("include"));
    wabt_lib.addCSourceFiles(.{
        .root = wabt_dep.path("."),
        .files = &wabt_files,
    });
    wabt_lib.linkLibCpp();

    const wat2wasm = b.addExecutable(.{
        .name = "wat2wasm",
        .target = target,
        .optimize = optimize,
    });
    wat2wasm.addConfigHeader(wabt_config_h);
    wat2wasm.addIncludePath(wabt_dep.path("include"));
    wat2wasm.addCSourceFile(.{
        .file = wabt_dep.path("src/tools/wat2wasm.cc"),
    });
    wat2wasm.linkLibCpp();
    wat2wasm.linkLibrary(wabt_lib);

    const wasm2wat = b.addExecutable(.{
        .name = "wasm2wat",
        .target = target,
        .optimize = optimize,
    });
    wasm2wat.addConfigHeader(wabt_config_h);
    wasm2wat.addIncludePath(wabt_dep.path("include"));
    wasm2wat.addCSourceFile(.{
        .file = wabt_dep.path("src/tools/wasm2wat.cc"),
    });
    wasm2wat.linkLibCpp();
    wasm2wat.linkLibrary(wabt_lib);

    return .{
        .wat2wasm = wat2wasm,
        .wasm2wat = wasm2wat,
    };
}

const wabt_files = [_][]const u8{
    "src/binary-reader-ir.cc",
    "src/binary-reader-logging.cc",
    "src/binary-reader.cc",
    "src/binary-writer-spec.cc",
    "src/binary-writer.cc",
    "src/binary.cc",
    "src/binding-hash.cc",
    "src/color.cc",
    "src/common.cc",
    "src/error-formatter.cc",
    "src/expr-visitor.cc",
    "src/feature.cc",
    "src/filenames.cc",
    "src/ir.cc",
    "src/leb128.cc",
    "src/lexer-source-line-finder.cc",
    "src/lexer-source.cc",
    "src/literal.cc",
    "src/opcode-code-table.c",
    "src/opcode.cc",
    "src/option-parser.cc",
    "src/resolve-names.cc",
    "src/shared-validator.cc",
    "src/stream.cc",
    "src/token.cc",
    "src/type-checker.cc",
    "src/utf8.cc",
    "src/validator.cc",
    "src/wast-lexer.cc",
    // wasm2wat
    "src/generate-names.cc",
    "src/apply-names.cc",
    "src/wast-parser.cc",
    "src/wat-writer.cc",
    "src/ir-util.cc",
};
