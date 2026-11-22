const std = @import("std");

const args_parser = @import("args_parser.zig");
const Ast = @import("Ast.zig");
const Diagnostics = @import("Diagnostics.zig");
const print = @import("pretty_print.zig").print;
const Vm = @import("Vm.zig");
const Opcode = Vm.Opcode;
const debug = @import("Vm/debug.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &stdout.interface;
    defer writer.flush() catch {};

    const tree = comptime args_parser.parseParams(
        \\<file>          : Runs the Vacite program in <file>
        \\--help -h       : Print help and exit
        \\--version -v    : Print version and exit
        \\--debug <dbg>   : Output debug information
        \\run <file>      : Runs the Vacite program in <file>
        \\ --debug <dbg>  : Output debug information
        \\ --help -h 
        \\fmt <file>      : Applies standardised formatting to <file>
        \\ --help -h
        \\
    );

    const helpString = comptime tree.helpString("vacite");

    const res = tree.parse(.{
        .file = args_parser.parsers.string,
        .dbg = args_parser.parsers.string,
    }, init.minimal.args, arena) catch |err| {
        switch (err) {
            error.LoneSingleDash => try writer.writeAll("[Error] Lone single dash\n"),
            error.SingleDashLong => try writer.writeAll("[Error] Single dash on a long form option\n"),
            error.UnexpectedArg => try writer.writeAll("[Error] Unexpected arg\n"),
            error.UnknownOption => try writer.writeAll("[Error] Unknown option\n"),
            error.NotEnoughArgs => try writer.writeAll(helpString),
            else => return err,
        }
        return;
    };

    switch (res.cmd) {
        .run => |run_cmd| {
            if (run_cmd.opts.help) {
                try writer.writeAll("Imagine the help for the `run` command here\n");
                return;
            }
            try run(arena, init.gpa, init.io, writer, run_cmd.pos_args.@"0");
        },
        .fmt => {
            try writer.writeAll("[Error] fmt command not implemented yet\n");
            return;
        },
        .none => {
            if (res.opts.version) {
                try writer.writeAll("0.0.1\n");
                return;
            }
            // both the case of no options and `help` should print help
            try writer.writeAll(helpString);
        },
        .pos_args => |pos_args| try run(arena, init.gpa, init.io, writer, pos_args.@"0"),
    }
}

fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    file_path: []const u8,
) !void {
    const file = std.Io.Dir.cwd().openFile(
        io,
        file_path,
        .{ .mode = .read_only },
    ) catch {
        try writer.print("[Error] Failed to open file '{s}'\n", .{file_path});
        return;
    };

    const stat = try file.stat(io);
    const file_contents = try arena.allocSentinel(u8, stat.size, 0);

    _ = try file.readPositionalAll(io, file_contents, 0);

    var diagnostics: Diagnostics = .init(gpa);
    defer diagnostics.deinit();

    var ast = Ast.parse(gpa, file_contents, writer, &diagnostics) catch |err| {
        if (err != error.ParseError) return err;
        return;
    };
    defer ast.deinit(gpa);

    try writer.print("{f}", .{ast});

    var vm = ast.genBytecode(gpa, writer, &diagnostics) catch |err| {
        if (err != error.GenError) return err;
        try diagnostics.reportAll(&ast, writer);
        return;
    };
    defer vm.deinit();

    try vm.run(writer);
}
