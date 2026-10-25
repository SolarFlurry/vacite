const std = @import("std");

const Vm = @import("../Vm.zig");
const StackFrame = Vm.StackFrame;
const BytecodeArray = Vm.BytecodeArray;
const Opcode = Vm.Opcode;

pub fn printDebug(s: *const StackFrame, writer: *std.Io.Writer) !void {
    try debugStackFrame(s, writer);
    try debugBytecode(&s.instrs, writer);
}

pub fn debugStackFrame(s: *const StackFrame, writer: *std.Io.Writer) !void {
    try writer.print("Accumulator: {d}\n", .{s.acc.int});
    try writer.writeAll("Register File:\n");

    for (s.reg_file, 0..) |value, i| {
        try writer.print("  r{d}: {d}\n", .{ i, value.int });
    }
}

pub fn debugBytecode(s: *const BytecodeArray, writer: *std.Io.Writer) !void {
    var i: usize = 0;

    while (i < s.bytecode.len) {
        try writer.print("{d: >4} | ", .{i});

        var opcode: Opcode = @enumFromInt(s.bytecode[i]);
        const width: u8 = switch (opcode) {
            .width16 => 2,
            .width32 => 3,
            .width64 => 4,
            else => 1,
        };

        if (width > 1) {
            i += 1;
            opcode = @enumFromInt(s.bytecode[i]);
        }

        const instr = opcode.asInstr();
        const instr_length = getInstrLength(instr, width);

        for (0..instr_length) |byte_offset| {
            try writer.print("{x:0>2} ", .{s.bytecode[i + byte_offset]});
        }
        try writer.splatBytesAll("   ", 4 - instr_length);

        switch (width) {
            inline 1...3 => |comp_width| {
                try writer.writeAll(.{ "", "w16_", "w32_", "w64_" }[comp_width - 1]);

                switch (instr) {
                    .store_to_reg => try opOneReg("str", s, writer, i, comp_width),
                    .load_from_reg => try opOneReg("ldr", s, writer, i, comp_width),
                    .load_int_imm => try opOneImm("ldi, ", s, writer, i, comp_width),
                    .load_constant => try opOneImm("ldc", s, writer, i, comp_width),
                    .func_return => try writer.writeAll("reg"),
                    .int_add_imm => try opOneImm("iaddi", s, writer, i, comp_width),
                    .int_sub_imm => try opOneImm("isubi", s, writer, i, comp_width),
                    .int_mul_imm => try opOneImm("imuli", s, writer, i, comp_width),
                    .int_div_imm => try opOneImm("idivi", s, writer, i, comp_width),
                    .int_add => try opOneReg("iadd", s, writer, i, comp_width),
                    .int_sub => try opOneReg("isub", s, writer, i, comp_width),
                    .int_mul => try opOneReg("imul", s, writer, i, comp_width),
                    .int_div => try opOneReg("idiv", s, writer, i, comp_width),
                    .str_write => try writer.writeAll("write"),
                }
            },
            else => unreachable,
        }

        try writer.writeByte('\n');

        i += instr_length;
    }
}

fn getInstrLength(instr: Opcode.Instr, width: u8) usize {
    switch (instr) {
        .str_write, .func_return => return 1,
        .load_int_imm,
        .load_constant,
        .store_to_reg,
        .load_from_reg,
        .int_add_imm,
        .int_sub_imm,
        .int_mul_imm,
        .int_div_imm,
        .int_add,
        .int_sub,
        .int_mul,
        .int_div,
        => return 1 + width,
    }
}

fn getIntWithWidth(bytes: []const u8, start: usize, comptime int_width: u8) @Int(.unsigned, 1 << int_width + 2) {
    return std.mem.readInt(@Int(.unsigned, 1 << int_width + 2), @ptrCast(bytes[start .. start + int_width]), .big);
}

fn opOneImm(
    name: []const u8,
    s: *const BytecodeArray,
    writer: *std.Io.Writer,
    i: usize,
    comptime width: u8,
) !void {
    const immediate = getIntWithWidth(s.bytecode, i + 1, width);

    try writer.print("{s} #{d}", .{ name, immediate });
}

fn opOneReg(
    name: []const u8,
    s: *const BytecodeArray,
    writer: *std.Io.Writer,
    i: usize,
    comptime width: u8,
) !void {
    const reg = getIntWithWidth(s.bytecode, i + 1, width);

    try writer.print("{s} r{d}", .{ name, reg });
}
