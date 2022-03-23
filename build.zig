const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("colosseum", "src/colosseum.zig");
    lib.setBuildMode(mode);
    lib.install();

    const exe_tests = b.addTestExe("debug_test", "src/colosseum.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);
    exe_tests.install();

    const main_tests = b.addTest("src/colosseum.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
