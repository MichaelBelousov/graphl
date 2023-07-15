const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{
        .default_target = std.zig.CrossTarget{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        },
    });

    const lib = b.addStaticLibrary("graph-lang", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();
    lib.force_pic = true;

    const main_tests = b.addTest("src/main.zig");
    // test use file buffer
    main_tests.linkLibC();
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const web_step = b.step("web", "Build for web");
    const web_lib = b.addExecutable("graph-lang", "src/main.zig");
    web_lib.setBuildMode(mode);
    var web_target = target;
    web_target.cpu_arch = .wasm32;
    web_target.os_tag = .freestanding;
    web_lib.setTarget(web_target);
    web_lib.install();
    web_step.dependOn(&web_lib.install_step.?.step);

    const ide_json_gen_step = b.step("ide-json-gen", "Build ide-json-gen");
    const ide_json_gen = b.addExecutable("ide-json-gen", "src/ide_json_gen.zig");
    ide_json_gen.setBuildMode(mode);
    ide_json_gen.setTarget(target);
    ide_json_gen.linkLibC();
    ide_json_gen.install();
    ide_json_gen_step.dependOn(&ide_json_gen.install_step.?.step);
}
