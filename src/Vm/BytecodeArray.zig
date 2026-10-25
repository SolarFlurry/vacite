const std = @import("std");
const Allocator = std.mem.Allocator;

const Vm = @import("../Vm.zig");
const Opcode = Vm.Opcode;

const BytecodeArray = @This();

bytecode: []const u8,
stack_size: usize,

pub fn deinit(s: *BytecodeArray, gpa: Allocator) void {
    gpa.free(s.bytecode);
}
