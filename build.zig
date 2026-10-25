const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const venge_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const venge_exe = b.addExecutable(.{
        .name = "venge",
        .root_module = venge_mod,
    });

    b.installArtifact(venge_exe);

    const venge_exe_run = b.addRunArtifact(venge_exe);

    const venge_exe_check = b.addExecutable(.{
        .name = "venge",
        .root_module = venge_mod,
    });

    venge_exe_run.addPassthruArgs();

    const run_step = b.step("run", "Run the resulting binary");
    run_step.dependOn(&venge_exe_run.step);

    const check_step = b.step("check", "Check step for ZLS");
    check_step.dependOn(&venge_exe_check.step);
}
