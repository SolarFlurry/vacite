const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Error = Allocator.Error;

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Vm = @import("Vm.zig");
const Opcode = Vm.Opcode;

const Self = @This();

gpa: Allocator,
bytecode: std.ArrayList(u8),
allocated_regs: u8,
stack_size: u8,
ast: *const Ast,

pub fn emitOp(s: *Self, op: Opcode) Error!void {
    std.debug.print("Emit op: .{s}\n", .{@tagName(op)});
    try s.bytecode.append(s.gpa, @backingInt(op));
}

pub fn allocReg(s: *Self) u8 {
    const result = s.allocated_regs;
    s.allocated_regs += 1;
    if (s.allocated_regs > s.stack_size) s.stack_size = s.allocated_regs;
    return result;
}

pub fn emitVal(s: *Self, value: anytype) Error!void {
    std.debug.print("Emit val: {any}\n", .{value});
    try s.bytecode.appendSlice(s.gpa, std.mem.asBytes(&value));
}

pub fn emitIntFromToken(s: *Self, tok_i: TokenIndex) Error!void {
    const token = s.ast.tokens.get(tok_i);

    // if the lexer correctly tokenises, then the string should be a valid integer (unless overflow)
    const int = std.fmt.parseInt(u8, s.ast.source[token.loc.start..token.loc.end], 10) catch unreachable;
    try s.emitVal(int);
}

pub fn genBytecode(s: *Self) Error!void {
    const root_node = s.ast.getNode(.root);

    try s.genExpr(root_node.data.node);
    try s.emitOp(.func_return);
}

fn genExpr(s: *Self, expr: Node.Index) Error!void {
    const node = s.ast.getNode(expr);
    switch (node.kind) {
        .infix_op => try s.genBinOp(node),
        .int_literal => try s.genInt(node),
        .identifier => @panic("Variables not supported yet"),
        .var_decl => unreachable,
        .func_decl => unreachable,
        .root => unreachable,
    }
}

fn genBinOp(s: *Self, node: Node) Error!void {
    const start_regs = s.allocated_regs;

    const op: Opcode = switch (s.ast.tokenTag(node.main_token)) {
        .plus => .int_add,
        .minus => .int_sub,
        .asterisk => .int_mul,
        .slash => .int_div,
        else => unreachable,
    };

    const rhs = s.ast.getNode(node.data.node_and_node.@"1");
    if (rhs.kind == .int_literal) {
        // if rhs is literal we can use the imm version instead
        // subtracting 4 to non-imm int op results in imm [Vm.zig:35]
        const imm_op: Opcode = @fromBackingInt(@backingInt(op) - 4);

        try s.genExpr(node.data.node_and_node.@"0");

        try s.emitOp(imm_op);
        try s.emitIntFromToken(rhs.main_token);
    } else {
        try s.genExpr(node.data.node_and_node.@"1");
        try s.emitOp(.store_to_reg);
        const rhs_reg = s.allocReg();
        try s.emitVal(rhs_reg);

        try s.genExpr(node.data.node_and_node.@"0");

        try s.emitOp(op);
        try s.emitVal(rhs_reg);
    }

    s.allocated_regs = start_regs;
}

fn genInt(s: *Self, node: Node) Error!void {
    try s.emitOp(.load_int_imm);
    try s.emitIntFromToken(node.main_token);
}
