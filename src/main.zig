const std = @import("std");
const Ast = @import("Ast.zig");
const Vm = @import("Vm.zig");
const debug = @import("Vm/debug.zig");

const Opcode = Vm.Opcode;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &stdout.interface;
    defer writer.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        try writer.writeAll(
            \\venge --help
            \\    venge run <file>     Runs the file at <file>
            \\    venge bytecode       BYTECODE!!
            \\
        );
        return;
    }

    if (std.mem.eql(u8, args[1], "run")) {
        return run(arena, init.gpa, init.io, writer, args);
    }

    if (std.mem.eql(u8, args[1], "bytecode")) {
        return bytecode(init.gpa, writer);
    }

    try writer.print("[Error] Unknown command '{s}'\n", .{args[1]});
}

fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    args: []const [:0]const u8,
) !void {
    if (args.len != 3) {
        try writer.print("[Error] Expected 1 argument, got {d}\n", .{args.len - 2});
        return;
    }

    const file = std.Io.Dir.cwd().openFile(
        io,
        args[2],
        .{ .mode = .read_only },
    ) catch {
        try writer.print("[Error] Failed to open file '{s}'\n", .{args[2]});
        return;
    };

    const stat = try file.stat(io);
    const file_contents = try arena.allocSentinel(u8, stat.size, 0);

    _ = try file.readPositionalAll(io, file_contents, 0);

    var ast = try Ast.parse(gpa, file_contents);
    defer ast.deinit(gpa);

    try writer.print("{f}", .{ast});

    // var lx: Lexer = .init(file_contents);
    // while (true) {
    //     const token = lx.next();
    //     if (token.tag == .eof) break;
    //     try writer.print(
    //         "\x1b[36m{s}\x1b[0m -> \x1b[33m'{s}'\x1b[0m\n",
    //         .{ @tagName(token.tag), file_contents[token.loc.start..token.loc.end] },
    //     );
    // }
}

fn bytecode(gpa: std.mem.Allocator, writer: *std.Io.Writer) !void {
    const constants: []const *const anyopaque = &.{
        &[8]u8{ 0, 0, 0, 0, 0, 0, 0, 14 } ++ "Hello, World!\n",
    };

    const instrs: []const u8 = &.{
        Opcode.load_constant.asByte(),
        0x00,
        Opcode.str_write.asByte(),
        Opcode.width16.asByte(),
        Opcode.load_int_imm.asByte(),
        0x03,
        0xe8,
        Opcode.int_div_imm.asByte(),
        5,
        Opcode.func_return.asByte(),
    };

    const bytecode_array: Vm.BytecodeArray = .{
        .bytecode = instrs,
        .stack_size = 1,
    };

    try writer.writeByte('\n');
    try debug.debugBytecode(&bytecode_array, writer);
    try writer.writeByte('\n');

    var vm: Vm = try .init(
        gpa,
        bytecode_array,
        constants,
    );
    defer vm.deinit();

    try vm.run(writer);

    try debug.debugStackFrame(&vm.stack_frames.items[0], writer);
}
