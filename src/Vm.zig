const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BytecodeArray = @import("Vm/BytecodeArray.zig");

const Vm = @This();

stack_frames: std.ArrayList(StackFrame),
constants: []const *const anyopaque,
gpa: Allocator,

pub const Value = extern union {
    int: i32,
    float: f64,
    // // a string that is 8 bytes or less. Null terminated if less than 8 bytes
    // small_str: [8]u8,
    heap_obj: *anyopaque,
};

pub const StackFrame = struct {
    instrs: []const u8,
    pc: usize,
    reg_file: []Value,
    acc: Value,
};

pub const Opcode = enum(u8) {
    // instrs
    load_from_reg,
    store_to_reg,
    load_int_imm,
    load_constant,
    func_return,
    int_add_imm,
    int_sub_imm,
    int_mul_imm,
    int_div_imm,
    int_add,
    int_sub,
    int_mul,
    int_div,

    str_write,

    // widths
    width16,
    width32,
    width64,

    pub fn isWidth(opcode: Opcode) bool {
        return opcode == .width16 or opcode == .width32 or opcode == .width64;
    }

    pub fn asInstr(opcode: Opcode) Instr {
        return @fromBackingInt(@intCast(@backingInt(opcode)));
    }

    pub fn asByte(opcode: Opcode) u8 {
        return @backingInt(opcode);
    }

    pub const Instr = instr: {
        const type_info = @typeInfo(Opcode).@"enum";

        var i: usize = 0;
        var field_names: [type_info.field_names.len][]const u8 = undefined;
        var field_values: [type_info.field_values.len]type_info.tag_type = undefined;
        for (type_info.field_names, type_info.field_values) |field_name, field_value| {
            if (@field(Opcode, field_name).isWidth()) {
                continue;
            }

            field_names[i] = field_name;
            field_values[i] = field_value;
            i += 1;
        }

        break :instr @Enum(
            type_info.tag_type,
            type_info.mode,
            field_names[0..i],
            field_values[0..i],
        );
    };
};

pub fn deinit(s: *Vm) void {
    s.gpa.free(s.stack_frames.items[0].reg_file);
    s.stack_frames.deinit(s.gpa);
}

pub fn run(s: *Vm, writer: *std.Io.Writer) error{WriteFailed}!void {
    while (true) {
        const stack_frame = &s.stack_frames.items[0];
        const opcode: Opcode = @fromBackingInt(@intCast(stack_frame.instrs[stack_frame.pc]));

        const width: u8 = switch (opcode) {
            .width16 => 2,
            .width32 => 3,
            .width64 => 4,
            else => 1,
        };

        if (opcode.isWidth()) stack_frame.pc += 1;

        const instr = @as(Opcode, @fromBackingInt(@intCast(stack_frame.instrs[stack_frame.pc]))).asInstr();

        stack_frame.pc += 1;

        switch (instr) {
            .load_int_imm => stack_frame.acc.int = readBytes(i32, stack_frame, width),
            .load_constant => stack_frame.acc.heap_obj = @constCast(s.constants[readBytes(usize, stack_frame, width)]),
            .store_to_reg => {
                const reg = readBytes(usize, stack_frame, width);
                stack_frame.reg_file[reg] = stack_frame.acc;
            },
            .int_add_imm => stack_frame.acc.int = stack_frame.acc.int + readBytes(i32, stack_frame, width),
            .int_sub_imm => stack_frame.acc.int = stack_frame.acc.int - readBytes(i32, stack_frame, width),
            .int_mul_imm => stack_frame.acc.int = stack_frame.acc.int * readBytes(i32, stack_frame, width),
            .int_div_imm => stack_frame.acc.int = @divTrunc(stack_frame.acc.int, readBytes(i32, stack_frame, width)),
            .int_add => {
                const reg = readBytes(usize, stack_frame, width);
                stack_frame.acc.int = stack_frame.acc.int + stack_frame.reg_file[reg].int;
            },
            .int_sub => {
                const reg = readBytes(usize, stack_frame, width);
                stack_frame.acc.int = stack_frame.acc.int - stack_frame.reg_file[reg].int;
            },
            .int_mul => {
                const reg = readBytes(usize, stack_frame, width);
                stack_frame.acc.int = stack_frame.acc.int * stack_frame.reg_file[reg].int;
            },
            .int_div => {
                const reg = readBytes(usize, stack_frame, width);
                stack_frame.acc.int = @divTrunc(stack_frame.acc.int, stack_frame.reg_file[reg].int);
            },
            .func_return => {
                try writer.writeAll("returned: ");

                const bytes = std.mem.asBytes(&stack_frame.acc);

                for (bytes) |byte| try writer.print("{x:0>2} ", .{byte});
                try writer.writeAll("  ");
                for (bytes) |byte| if (byte >= 21 and byte <= 126) try writer.writeByte(byte) else try writer.writeByte('.');
                try writer.writeByte('\n');

                return;
            },

            .str_write => {
                const raw_ptr: [*]const u8 = @ptrCast(stack_frame.acc.heap_obj);
                const len = std.mem.readInt(usize, raw_ptr[0..@sizeOf(usize)], .big);
                const bytes = raw_ptr[@sizeOf(usize) .. @sizeOf(usize) + len];

                try writer.writeAll(bytes);
            },

            else => {
                try writer.print("Error: Instruction not supported: '{s}'\n", .{@tagName(instr)});
                return;
            },
        }
    }
}

fn readBytes(comptime T: type, stack_frame: *StackFrame, width: u8) T {
    const type_info = @typeInfo(T);
    const signedness = if (type_info == .int) type_info.int.signedness else .unsigned;

    switch (width) {
        inline 1...3 => |w| {
            const WorkingType = @Int(signedness, 1 << (w + 2));

            const thing: WorkingType = std.mem.readInt(
                WorkingType,
                @ptrCast(stack_frame.instrs[stack_frame.pc .. stack_frame.pc + width]),
                .native,
            );

            stack_frame.pc += width;

            return thing;
        },
        else => unreachable,
    }
}
