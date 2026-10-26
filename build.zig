const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vacite_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vacite_exe = b.addExecutable(.{
        .name = "vacite",
        .root_module = vacite_mod,
    });

    b.installArtifact(vacite_exe);

    const vacite_exe_run = b.addRunArtifact(vacite_exe);

    const vacite_exe_check = b.addExecutable(.{
        .name = "vacite",
        .root_module = vacite_mod,
    });

    vacite_exe_run.addPassthruArgs();

    const run_step = b.step("run", "Run the resulting binary");
    run_step.dependOn(&vacite_exe_run.step);

    const check_step = b.step("check", "Check step for ZLS");
    check_step.dependOn(&vacite_exe_check.step);
}
