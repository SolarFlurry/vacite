const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
pub const Scope = @import("BytecodeGen/scope.zig").Scope;
pub const Symbol = @import("BytecodeGen/Symbol.zig");
const Diagnostics = @import("Diagnostics.zig");
const Diagnostic = Diagnostics.Diagnostic;
const Span = @import("Lexer.zig").Span;
const Vm = @import("Vm.zig");
const Opcode = Vm.Opcode;
const debug = @import("Vm/debug.zig");

pub const Error = Allocator.Error || error{ GenError, WriteFailed };

const Self = @This();

pub const SymbolTable = struct {
    scopes: std.MultiArrayList(Scope),

    pub fn init() SymbolTable {
        return .{
            .scopes = .empty,
        };
    }

    pub fn deinit(s: *SymbolTable, gpa: Allocator) void {
        return s.scopes.deinit(gpa);
    }

    pub fn getSymbol(s: *const SymbolTable, ident: []const u8) ?Symbol {
        for (0..s.scopes.len) |i| {
            const item = s.scopes.get(i);
            switch (item) {
                .var_decl => |d| if (std.mem.eql(u8, d.ident, ident)) return d.symbol,
            }
        }

        return null;
    }
};

gpa: Allocator,
/// the allocator used to store constant Bytecode and strings
constants_arena: Allocator,
/// the array of pointers to constants allocated in `constants_arena`
constants: std.ArrayList(*const anyopaque),
/// the in progress bytecode emitted
bytecode: std.ArrayList(u8),
symbol_table: SymbolTable,
writer: *std.Io.Writer,
allocated_regs: u8,
stack_size: u8,
last_emitted_op: Opcode = .call,
ast: *const Ast,
diagnositcs: *Diagnostics,

fn failError(s: *Self, data: Diagnostic.Data, span: Span) Error {
    try s.diagnositcs.add(.{ .level = .@"error", .data = data, .span = span });
    return error.GenError;
}

pub fn pushScope(s: *Self, scope: Scope) Allocator.Error!void {
    return s.symbol_table.scopes.append(s.gpa, scope);
}

pub fn emitOp(s: *Self, op: Opcode) Error!void {
    // std.debug.print("Emit op: .{s}\n", .{@tagName(op)});
    try s.bytecode.append(s.gpa, @backingInt(op));
    s.last_emitted_op = op;
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
    const bytecode = try s.constants_arena.alignedAlloc(u8, .@"8", 8 + s.bytecode.items.len);

    try debug.debugBytecode(s.bytecode.items, s.writer);
    try s.writer.writeByte('\n');

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
        .var_decl => {
            return s.failError(
                .{ .direct_msg = "variable declarations at container scope not supported" },
                s.ast.tokenSpan(node.main_token),
            );
        },
        else => unreachable,
    }
}

fn genFuncDecl(s: *Self, decl: Node.Index) Error!void {
    s.bytecode = .empty;
    defer s.bytecode.deinit(s.gpa);

    const decl_node = s.ast.getNode(decl);
    const block = decl_node.data.node_and_node.@"1";

    try s.genBlock(block);

    if (s.last_emitted_op != .func_return) {
        try s.emitOp(.func_return);
    }

    const constant = try s.createBytecode();

    try s.pushScope(.{ .var_decl = .{
        .ident = s.ast.tokenString(decl_node.main_token + 1),
        .symbol = .{
            .value = .{ .constant = constant },
            .type = .{ .kind = .int },
        },
        .is_var = false,
    } });
}

fn genVarDecl(s: *Self, decl: Node.Index) Error!void {
    const node = s.ast.getNode(decl);

    const var_reg = s.allocReg();
    try s.genExpr(node.data.node_and_opt.@"0");

    try s.emitOp(.store_to_reg);
    try s.emitVal(var_reg);

    try s.pushScope(.{
        .var_decl = .{
            .is_var = s.ast.tokenTag(node.main_token) == .keyword_var,
            .ident = s.ast.tokenString(node.main_token + 1),
            .symbol = .{
                .type = .{ .kind = .int },
                .value = .{ .reg = var_reg },
            },
        },
    });
}

fn genBlock(s: *Self, block: Node.Index) Error!void {
    const node = s.ast.getNode(block);

    const start_regs = s.allocated_regs;

    const stmts = s.ast.extraDataSlice(node.data.extra_range, Node.Index);

    for (stmts) |stmt| {
        const stmt_node = s.ast.getNode(stmt);
        switch (stmt_node.kind) {
            .var_decl => try s.genVarDecl(stmt),
            else => try s.genExpr(stmt),
        }
    }

    s.allocated_regs = start_regs;
}

fn genExpr(s: *Self, expr: Node.Index) Error!void {
    const node = s.ast.getNode(expr);
    switch (node.kind) {
        .infix_op => try s.genBinOp(node),
        .prefix_op => @panic("Prefix op not implemented yet"),
        .int_literal => try s.genInt(node),
        .identifier => {
            const token = s.ast.tokens.get(node.main_token);
            const name = s.ast.source[token.loc.start..token.loc.end];

            const symbol = s.symbol_table.getSymbol(name) orelse {
                return s.failError(
                    .{ .direct_msg = "Use of undeclared identifier" },
                    s.ast.tokenSpan(node.main_token),
                );
            };

            switch (symbol.value) {
                .reg => |reg| {
                    try s.emitOp(.load_from_reg);
                    try s.emitVal(reg);
                },
                .constant => |constant| {
                    try s.emitOp(.width64);
                    try s.emitOp(.load_constant);
                    try s.emitVal(constant);
                },
            }
        },
        .block => @panic("Blocks not supported yet"),
        .string_literal => @panic("Strings not implemented yet"),
        .func_call => {
            try s.genExpr(node.data.node_and_extra.node);
            try s.emitOp(.call);
        },
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
        // subtracting 4 to non-imm int op results in imm [`@import("Vm.zig").Opcode`]
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
