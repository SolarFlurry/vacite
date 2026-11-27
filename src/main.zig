const std = @import("std");

const args_parser = @import("args_parser.zig");
const Ast = @import("Ast.zig");
const debug = @import("debug.zig");
const Diagnostics = @import("Diagnostics.zig");
const print = @import("pretty_print.zig").print;
const Vm = @import("Vm.zig");
const Opcode = Vm.Opcode;

const DebugFlags = packed struct {
    tokens: bool = false,
    ast: bool = false,
    bytecode: bool = false,
    _: u5 = undefined,
};

fn parseDbg(in: []const u8) error{UnknownDebugFlag}!DebugFlags {
    var flags: DebugFlags = .{};
    for (in) |c| {
        switch (c) {
            't' => flags.tokens = true,
            'a' => flags.ast = true,
            'b' => flags.bytecode = true,
            else => return error.UnknownDebugFlag,
        }
    }
    return flags;
}

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
        \\run <file>      : Runs the Vacite program in <file>
        \\ --debug <dbg>  : Output debug information
        \\ --help -h 
        \\fmt <file>      : Applies standardised formatting to <file>
        \\ --help -h
        \\
    );

    const helpString = comptime tree.helpString("vacite");

    var diag: args_parser.Diagnostics = undefined;

    const res = tree.parse(.{
        .file = args_parser.parsers.string,
        .dbg = parseDbg,
    }, init.minimal.args, arena, &diag) catch |err| {
        switch (err) {
            error.LoneSingleDash => try print(writer, "<r>[Error]<0> Lone single dash\n", .{}),
            error.SingleDashLong => try print(writer, "<r>[Error]<0> Single dash on a long form option '{s}'\n", .{diag.offender}),
            error.UnexpectedArg => try print(writer, "<r>[Error]<0> Unexpected arg '{s}'\n", .{diag.offender}),
            error.UnknownOption => try print(writer, "<r>[Error]<0> Unknown option '{s}'\n", .{diag.offender}),
            error.UnknownDebugFlag => try print(writer, "<r>[Error]<0> Unknown debug flag '{s}', the accepted values are 't', 'a' and 'b'\n", .{diag.offender}),
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
            try run(
                arena,
                init.gpa,
                init.io,
                writer,
                run_cmd.pos_args.@"0",
                run_cmd.opts.debug orelse .{},
            );
        },
        .fmt => {
            try print(writer, "<r>[Error]<0> fmt command not implemented yet\n", .{});
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
        .pos_args => |pos_args| try run(arena, init.gpa, init.io, writer, pos_args.@"0", .{}),
    }
}

fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    file_path: []const u8,
    debug_flags: DebugFlags,
) !void {
    const file = std.Io.Dir.cwd().openFile(
        io,
        file_path,
        .{ .mode = .read_only },
    ) catch {
        try print(writer, "<r>[Error]<0> Failed to open file '<y>{s}<0>'\n", .{file_path});
        return;
    };
    defer file.close(io);

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

    if (debug_flags.tokens) try debug.debugTokens(&ast, writer);
    if (debug_flags.ast) try debug.debugAst(&ast, writer);

    var vm = ast.genBytecode(gpa, writer, &diagnostics, debug_flags.bytecode) catch |err| {
        if (err != error.GenError) return err;
        try diagnostics.reportAll(&ast, writer);
        return;
    };
    defer vm.deinit();

    try vm.run(writer);
}

test {
    std.testing.refAllDecls(@This());
}
