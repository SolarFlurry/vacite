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
/// the allocator used to store constant Bytecode and strings
arena: Allocator,
constants: std.ArrayList(*const anyopaque),
bytecode: std.ArrayList(u8),
allocated_regs: u8,
stack_size: u8,
ast: *const Ast,

pub fn emitOp(s: *Self, op: Opcode) Error!void {
    // std.debug.print("Emit op: .{s}\n", .{@tagName(op)});
    try s.bytecode.append(s.gpa, @backingInt(op));
}

pub fn allocReg(s: *Self) u8 {
    const result = s.allocated_regs;
    s.allocated_regs += 1;
    if (s.allocated_regs > s.stack_size) s.stack_size = s.allocated_regs;
    return result;
}

pub fn emitVal(s: *Self, value: anytype) Error!void {
    // std.debug.print("Emit val: {any}\n", .{value});
    try s.bytecode.appendSlice(s.gpa, std.mem.asBytes(&value));
}

pub fn emitIntFromToken(s: *Self, tok_i: TokenIndex) Error!void {
    const token = s.ast.tokens.get(tok_i);

    // if the lexer correctly tokenises, then the string should be a valid integer (unless overflow)
    const int = std.fmt.parseInt(u8, s.ast.source[token.loc.start..token.loc.end], 10) catch unreachable;
    try s.emitVal(int);
}

/// creates the bytecode and pushes it to the constants array
/// layout:
///     [0..4] len of the bytecode
///     [4..8] number of registers (stack size)
///     [8..] bytecode instructions
fn createBytecode(s: *Self) Error!usize {
    const bytecode = try s.arena.alignedAlloc(u8, .@"8", 8 + s.bytecode.items.len);

    // write the bytecode len and stack size
    std.mem.writeInt(u32, bytecode[0..4], @intCast(s.bytecode.items.len), .native);
    std.mem.writeInt(u32, bytecode[4..8], s.stack_size, .native);

    @memcpy(bytecode[8..], s.bytecode.items);

    const result = s.constants.items.len;
    try s.constants.append(s.gpa, bytecode.ptr);
    return result;
}

pub fn genBytecode(s: *Self) Error!void {
    const root_node = s.ast.getNode(.root);

    for (s.ast.extraDataSlice(root_node.data.extra_range, Node.Index)) |node| {
        try s.genDecl(node);
    }
}

fn genDecl(s: *Self, decl: Node.Index) Error!void {
    const node = s.ast.getNode(decl);
    switch (node.kind) {
        .func_decl => return s.genFuncDecl(decl),
        .var_decl => @panic("var decls at container scope not implemented yet"),
        else => unreachable,
    }
}

fn genFuncDecl(s: *Self, decl: Node.Index) Error!void {
    s.bytecode.deinit(s.gpa);
    s.bytecode = .empty;
    defer s.bytecode.deinit(s.gpa);

    const decl_node = s.ast.getNode(decl);
    const block = decl_node.data.node_and_node.@"1";
    const block_node = s.ast.getNode(block);

    for (s.ast.extraDataSlice(block_node.data.extra_range, Node.Index)) |node| {
        try s.genExpr(node);
    }

    try s.emitOp(.func_return);

    _ = try s.createBytecode();
}

fn genExpr(s: *Self, expr: Node.Index) Error!void {
    const node = s.ast.getNode(expr);
    switch (node.kind) {
        .infix_op => try s.genBinOp(node),
        .prefix_op => @panic("Prefix op not implemented yet"),
        .int_literal => try s.genInt(node),
        .identifier => @panic("Variables not supported yet"),
        .block => @panic("Blocks not supported yet"),
        .@"return" => try s.genReturn(node),
        .var_decl => unreachable,
        .func_decl => unreachable,
        .func_proto => unreachable,
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

fn genReturn(s: *Self, node: Node) Error!void {
    if (node.data.opt.toOptional()) |expr| {
        try s.genExpr(expr);
    }

    try s.emitOp(.func_return);
}
