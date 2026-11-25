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

pub fn debugBytecode(s: []const u8, instrs_offset: usize, writer: *std.Io.Writer) !void {
    var i: usize = instrs_offset;

    while (i < s.len) {
        try writer.print("{d: >4} | ", .{i});

        var opcode: Opcode = @fromBackingInt(@intCast(s[i]));
        const width: u8 = switch (opcode) {
            .width16 => 2,
            .width32 => 3,
            .width64 => 4,
            else => 1,
        };

        if (width > 1) {
            i += 1;
            opcode = @fromBackingInt(@intCast(s[i]));
        }

        const instr = opcode.asInstr();
        const instr_length = getInstrLength(instr, width);

        for (0..instr_length) |byte_offset| {
            try writer.print("{x:0>2} ", .{s[i + byte_offset]});
        }
        try writer.splatBytesAll("   ", 10 - instr_length);

        switch (width) {
            inline 1...4 => |w| {
                try writer.writeAll(.{ "", "w16_", "w32_", "w64_" }[w - 1]);

                switch (instr) {
                    .store_to_reg => try writer.print("star : r{d} = acc", .{readInt(s, i + 1, w)}),
                    .load_from_reg => try writer.print("ldra : acc = r{d}", .{readInt(s, i + 1, w)}),
                    .load_int_imm => try writer.print("ldia : acc = {d}", .{readInt(s, i + 1, w)}),
                    .load_constant => try writer.print("ldca : acc = c{d}", .{readInt(s, i + 1, w)}),
                    .call => try writer.writeAll("call"),
                    .func_return => try writer.writeAll("ret"),
                    .int_add_imm => try writer.print("iaddi : acc += {d}", .{readInt(s, i + 1, w)}),
                    .int_sub_imm => try writer.print("isubi : acc -= {d}", .{readInt(s, i + 1, w)}),
                    .int_mul_imm => try writer.print("imuli : acc *= {d}", .{readInt(s, i + 1, w)}),
                    .int_div_imm => try writer.print("idivi : acc /= {d}", .{readInt(s, i + 1, w)}),
                    .int_add => try writer.print("iadd : acc += r{d}", .{readInt(s, i + 1, w)}),
                    .int_sub => try writer.print("isub : acc -= r{d}", .{readInt(s, i + 1, w)}),
                    .int_mul => try writer.print("imul : acc *= r{d}", .{readInt(s, i + 1, w)}),
                    .int_div => try writer.print("idiv : acc /= r{d}", .{readInt(s, i + 1, w)}),
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
        .str_write, .func_return, .call => return 1,
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
        => return 1 + (@as(usize, 1) << @intCast(width - 1)),
    }
}

fn readInt(bytes: []const u8, start: usize, comptime int_width: u8) @Int(.unsigned, 1 << int_width + 2) {
    return std.mem.readInt(@Int(.unsigned, 1 << int_width + 2), @ptrCast(bytes[start .. start + int_width]), .native);
}

fn opOneImm(
    name: []const u8,
    s: []const u8,
    writer: *std.Io.Writer,
    i: usize,
    comptime width: u8,
) !void {
    const immediate = readInt(s, i + 1, width);

    try writer.print("{s} #{d}", .{ name, immediate });
}

fn opOneReg(
    name: []const u8,
    s: []const u8,
    writer: *std.Io.Writer,
    i: usize,
    comptime width: u8,
) !void {
    const reg = readInt(s, i + 1, width);

    try writer.print("{s} r{d}", .{ name, reg });
}
