const std = @import("std");

const Ast = @import("Ast.zig");
const Vm = @import("Vm.zig");
const Opcode = Vm.Opcode;
const debug = @import("Vm/debug.zig");

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

    var ast = Ast.parse(gpa, file_contents, writer) catch |err| {
        if (err != error.ParseError) return err;
        return;
    };
    defer ast.deinit(gpa);

    try writer.print("{f}", .{ast});

    try ast.interpret(gpa, writer);
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
    try debug.debugBytecode(instrs, writer);
    try writer.writeByte('\n');

    var vm: Vm = .{
        .stack_frames = .empty,
        .gpa = gpa,
        .constants = constants,
    };
    try vm.stack_frames.append(gpa, .{
        .reg_file = try gpa.alloc(Vm.Value, bytecode_array.stack_size),
        .pc = 0,
        .instrs = bytecode_array.bytecode,
        .acc = undefined,
    });

    defer vm.deinit();

    try vm.run(writer);

    try debug.debugStackFrame(&vm.stack_frames.items[0], writer);
}
