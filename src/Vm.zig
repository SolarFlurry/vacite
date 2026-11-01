const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BytecodeArray = @import("Vm/BytecodeArray.zig");

const Vm = @This();

stack: std.ArrayList(usize),
constants: []const *const anyopaque,
acc: Value,
arena: std.heap.ArenaAllocator,
gpa: Allocator,
/// program counter
pc: usize,
/// frame pointer
fp: usize,

pub const Value = extern union {
    int: i64,
    float: f64,
    // // a string that is 8 bytes or less. Null terminated if less than 8 bytes
    // small_str: [8]u8,
    heap_obj: *anyopaque,

    pub fn toUsize(val: Value) usize {
        return @as(*const usize, @ptrCast(&val)).*;
    }

    pub fn fromUsize(val: usize) Value {
        return @as(*const Value, @ptrCast(&val)).*;
    }
};

pub const StackFrameHeader = struct {
    instrs: []const u8,
    callee_pc: usize,
    callee_fp: usize,
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
    s.stack.deinit(s.gpa);
    s.arena.deinit();
}

pub fn pushStackFrame(s: *Vm, instrs: []const u8, reg_file_size: usize) error{OutOfMemory}!void {
    const stack_frame: StackFrameHeader = .{
        .instrs = instrs,
        .callee_pc = s.pc,
        .callee_fp = s.fp,
    };

    try s.stack.ensureTotalCapacity(s.gpa, s.stack.items.len + 4 + reg_file_size);

    s.fp = s.stack.items.len;

    s.stack.appendAssumeCapacity(@intFromPtr(stack_frame.instrs.ptr));
    s.stack.appendAssumeCapacity(stack_frame.instrs.len);
    s.stack.appendAssumeCapacity(stack_frame.callee_pc);
    s.stack.appendAssumeCapacity(stack_frame.callee_fp);

    s.stack.items.len += reg_file_size;
    s.pc = 0;
}

pub fn currentStackFrame(s: *Vm) StackFrameHeader {
    const instrs_ptr: [*]const u8 = @ptrFromInt(s.stack.items[s.fp]);

    return .{
        .instrs = instrs_ptr[0..s.stack.items[s.fp + 1]],
        .callee_pc = s.stack.items[s.fp + 2],
        .callee_fp = s.stack.items[s.fp + 3],
    };
}

fn getReg(s: *Vm, reg: usize) Value {
    return .fromUsize(s.stack.items[s.fp + 4 + reg]);
}

fn setReg(s: *Vm, reg: usize, value: Value) void {
    s.stack.items[s.fp + 4 + reg] = value.toUsize();
}

fn readInstr(s: *Vm) Opcode {
    const result: Opcode = @fromBackingInt(s.currentStackFrame().instrs[s.pc]);
    s.pc += 1;
    return result;
}

fn readBytes(s: *Vm, comptime T: type, width: u8) T {
    const type_info = @typeInfo(T);
    const signedness = if (type_info == .int) type_info.int.signedness else .unsigned;

    switch (width) {
        inline 1...4 => |w| {
            const WorkingType = @Int(signedness, 1 << (w + 2));

            const thing: WorkingType = std.mem.readInt(
                WorkingType,
                @ptrCast(s.currentStackFrame().instrs[s.pc .. s.pc + width]),
                .native,
            );

            s.pc += 1 << (w - 1);

            return thing;
        },
        else => unreachable,
    }
}

pub fn run(s: *Vm, writer: *std.Io.Writer) error{ WriteFailed, OutOfMemory }!void {
    while (true) {
        const opcode = s.readInstr();

        const width: u8 = switch (opcode) {
            .width16 => 2,
            .width32 => 3,
            .width64 => 4,
            else => 1,
        };

        const instr: Opcode.Instr = if (opcode.isWidth())
            s.readInstr().asInstr()
        else
            opcode.asInstr();

        switch (instr) {
            .load_int_imm => s.acc = .{ .int = s.readBytes(i64, width) },
            .load_constant => s.acc.heap_obj = @constCast(s.constants[s.readBytes(usize, width)]),
            .store_to_reg => {
                const reg = s.readBytes(usize, width);
                s.setReg(reg, s.acc);
            },
            .load_from_reg => {
                const reg = s.readBytes(usize, width);
                s.acc = s.getReg(reg);
            },
            .int_add_imm => s.acc.int = s.acc.int + s.readBytes(i64, width),
            .int_sub_imm => s.acc.int = s.acc.int - s.readBytes(i64, width),
            .int_mul_imm => s.acc.int = s.acc.int * s.readBytes(i64, width),
            .int_div_imm => s.acc.int = @divTrunc(s.acc.int, s.readBytes(i64, width)),
            .int_add => {
                const reg = s.readBytes(usize, width);
                s.acc.int = s.acc.int + s.getReg(reg).int;
            },
            .int_sub => {
                const reg = s.readBytes(usize, width);
                s.acc.int = s.acc.int - s.getReg(reg).int;
            },
            .int_mul => {
                const reg = s.readBytes(usize, width);
                s.acc.int = s.acc.int * s.getReg(reg).int;
            },
            .int_div => {
                const reg = s.readBytes(usize, width);
                s.acc.int = @divTrunc(s.acc.int, s.getReg(reg).int);
            },

            .func_return => {
                try writer.writeAll("returned: ");

                const bytes = std.mem.asBytes(&s.acc);

                for (bytes) |byte| try writer.print("{x:0>2} ", .{byte});
                try writer.writeAll("  ");
                for (bytes) |byte| if (byte >= 21 and byte <= 126) try writer.writeByte(byte) else try writer.writeByte('.');
                try writer.writeByte('\n');

                const stack_frame = s.currentStackFrame();

                s.stack.shrinkRetainingCapacity(s.fp);

                if (s.stack.items.len == 0) return;

                s.pc = stack_frame.callee_pc;
                s.fp = stack_frame.callee_fp;
            },

            .call => {
                const bytecode_ptr: [*]const u8 = @ptrCast(s.acc.heap_obj);
                const bytecode = getBytecodeArrayFromPtr(bytecode_ptr);

                try s.pushStackFrame(bytecode.bytecode, bytecode.stack_size);
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
