const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("graph-lang", "main.zig");
    lib.setBuildMode(mode);
    lib.install();
    lib.force_pic = true;

    const main_tests = b.addTest("main.zig");
    // test use file buffer
    main_tests.linkLibC();
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const web_step = b.step("web", "Build for web");
    const web_lib = b.addExecutable("graph-lang", "main.zig");
    web_lib.setBuildMode(mode);
    const web_target = b.standardTargetOptions(.{
        .default_target = std.zig.CrossTarget{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        },
    });
    web_lib.setTarget(web_target);
    web_lib.install();
    web_step.dependOn(&web_lib.install_step.?.step);
}
