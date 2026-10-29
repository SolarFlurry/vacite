const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BytecodeArray = @import("Vm/BytecodeArray.zig");

const Vm = @This();

stack_frames: std.ArrayList(StackFrame),
constants: []const *const anyopaque,
acc: Value,
arena: std.heap.ArenaAllocator,
gpa: Allocator,

pub const Value = extern union {
    int: i64,
    float: f64,
    // // a string that is 8 bytes or less. Null terminated if less than 8 bytes
    // small_str: [8]u8,
    heap_obj: *anyopaque,
};

pub const StackFrame = struct {
    instrs: []const u8,
    pc: usize,
    reg_file: []Value,
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

    call,

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

pub fn getBytecodeArrayFromPtr(bytecode_ptr: [*]const u8) BytecodeArray {
    const len = std.mem.readInt(u32, bytecode_ptr[0..4], .native);
    const stack_size = std.mem.readInt(u32, bytecode_ptr[4..8], .native);
    const instrs = bytecode_ptr[8 .. 8 + len];

    return .{
        .bytecode = instrs,
        .stack_size = stack_size,
    };
}

pub fn deinit(s: *Vm) void {
    s.stack_frames.deinit(s.gpa);
    s.arena.deinit();
}

pub fn run(s: *Vm, writer: *std.Io.Writer) error{ WriteFailed, OutOfMemory }!void {
    while (true) {
        const stack_frame = s.stack_frames.lastPtr().?;
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
            .load_int_imm => s.acc.int = readBytes(i64, stack_frame, width),
            .load_constant => s.acc.heap_obj = @constCast(s.constants[readBytes(usize, stack_frame, width)]),
            .store_to_reg => {
                const reg = readBytes(usize, stack_frame, width);
                stack_frame.reg_file[reg] = s.acc;
            },
            .load_from_reg => {
                const reg = readBytes(usize, stack_frame, width);
                s.acc = stack_frame.reg_file[reg];
            },
            .int_add_imm => s.acc.int = s.acc.int + readBytes(i64, stack_frame, width),
            .int_sub_imm => s.acc.int = s.acc.int - readBytes(i64, stack_frame, width),
            .int_mul_imm => s.acc.int = s.acc.int * readBytes(i64, stack_frame, width),
            .int_div_imm => s.acc.int = @divTrunc(s.acc.int, readBytes(i64, stack_frame, width)),
            .int_add => {
                const reg = readBytes(usize, stack_frame, width);
                s.acc.int = s.acc.int + stack_frame.reg_file[reg].int;
            },
            .int_sub => {
                const reg = readBytes(usize, stack_frame, width);
                s.acc.int = s.acc.int - stack_frame.reg_file[reg].int;
            },
            .int_mul => {
                const reg = readBytes(usize, stack_frame, width);
                s.acc.int = s.acc.int * stack_frame.reg_file[reg].int;
            },
            .int_div => {
                const reg = readBytes(usize, stack_frame, width);
                s.acc.int = @divTrunc(s.acc.int, stack_frame.reg_file[reg].int);
            },

            .func_return => {
                try writer.writeAll("returned: ");

                const bytes = std.mem.asBytes(&s.acc);

                for (bytes) |byte| try writer.print("{x:0>2} ", .{byte});
                try writer.writeAll("  ");
                for (bytes) |byte| if (byte >= 21 and byte <= 126) try writer.writeByte(byte) else try writer.writeByte('.');
                try writer.writeByte('\n');

                s.gpa.free(s.stack_frames.last().?.reg_file);

                s.stack_frames.shrinkRetainingCapacity(s.stack_frames.items.len - 1);

                if (s.stack_frames.items.len == 0) return;
            },

            .call => {
                const bytecode_ptr: [*]const u8 = @ptrCast(s.acc.heap_obj);
                const bytecode = getBytecodeArrayFromPtr(bytecode_ptr);

                try s.stack_frames.append(s.gpa, .{
                    .reg_file = try s.gpa.alloc(Value, bytecode.stack_size),
                    .pc = 0,
                    .instrs = bytecode.bytecode,
                });
            },

            .str_write => {
                const raw_ptr: [*]const u8 = @ptrCast(s.acc.heap_obj);
                const len = std.mem.readInt(usize, raw_ptr[0..@sizeOf(usize)], .big);
                const bytes = raw_ptr[@sizeOf(usize) .. @sizeOf(usize) + len];

                try writer.writeAll(bytes);
            },

            // else => {
            //     try writer.print("Error: Instruction not supported: '{s}' at index {d}\n", .{ @tagName(instr), stack_frame.pc });
            //     return;
            // },
        }
    }
}

fn readBytes(comptime T: type, stack_frame: *StackFrame, width: u8) T {
    const type_info = @typeInfo(T);
    const signedness = if (type_info == .int) type_info.int.signedness else .unsigned;

    switch (width) {
        inline 1...4 => |w| {
            const WorkingType = @Int(signedness, 1 << (w + 2));

            const thing: WorkingType = std.mem.readInt(
                WorkingType,
                @ptrCast(stack_frame.instrs[stack_frame.pc .. stack_frame.pc + width]),
                .native,
            );

            stack_frame.pc += 1 << (w - 1);

            return thing;
        },
        else => unreachable,
    }
}
