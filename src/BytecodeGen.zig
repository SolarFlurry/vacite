const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Diagnostics = @import("Diagnostics.zig");
const Diagnostic = Diagnostics.Diagnostic;
const Span = @import("Lexer.zig").Span;
const Vm = @import("Vm.zig");
const Opcode = Vm.Opcode;
const debug = @import("Vm/debug.zig");

pub const Error = Allocator.Error || error{ GenError, WriteFailed };

const Self = @This();

gpa: Allocator,
/// the allocator used to store the scopes
scope_arena: Allocator,
/// the allocator used to store constant Bytecode and strings
constants_arena: Allocator,
/// the array of pointers to constants allocated in `constants_arena`
constants: std.ArrayList(*const anyopaque),
/// the index into `constants` of the entry point function
entry_fn: ?usize,
/// the in progress bytecode emitted
bytecode: std.ArrayList(u8),
/// the types constructed
types: std.MultiArrayList(Type),
/// extra data associated with types
types_data: std.ArrayList(u32),
writer: *std.Io.Writer,
allocated_regs: u8,
stack_size: u8,
last_emitted_op: Opcode = .call,
ast: *const Ast,
diagnositcs: *Diagnostics,

pub const ExtraIndex = enum(u32) { _ };

pub const Symbol = struct {
    value: Value,
    type: Type.Ref,

    pub fn atomicType(ref: Type.Ref) Symbol {
        return .{
            .value = .{ .type = ref },
            .type = .type,
        };
    }

    pub const Value = union(enum) {
        /// index into constants array
        constant: usize,
        /// allocated register
        reg: u8,
        /// holds a compile time type value
        type: Type.Ref,
    };
};

pub const Type = union(enum(u8)) {
    func: struct {
        return_type: Ref,
    },

    pub const Ref = enum(u32) {
        int,
        real,
        bool,
        str,
        type,
        void,
        noreturn,
        poison,
        _,

        pub const static_len = @typeInfo(Ref).@"enum".field_names.len;

        pub fn fromIdx(index: usize) Ref {
            return @fromBackingInt(@intCast(index + static_len));
        }

        /// assumes `isIdx() == true`
        pub fn toIdx(ref: Ref) usize {
            return @backingInt(ref) - static_len;
        }

        pub fn isIdx(ref: Ref) bool {
            return @backingInt(ref) >= static_len;
        }

        pub fn toString(t: Ref) []const u8 {
            switch (t) {
                .int => return "int",
                .real => return "real",
                .bool => return "bool",
                .str => return "str",
                .type => return "type",
                .void => return "void",
                .noreturn => return "noreturn",
                else => return "(unknown)",
            }
        }
    };

    pub fn eql(a: Ref, b: Ref) bool {
        return a == b;
    }

    pub fn compatible(a: Ref, b: Ref) bool {
        if (a.kind == .poison or b.kind == .poison) return true;
        if (a.kind == .noreturn or b.kind == .noreturn) return true;
        if (eql(a, b)) return true;

        if (a.kind == .real and b.kind == .int or
            b.kind == .real and a.kind == .int)
        {
            return true;
        }

        return false;
    }

    /// returns the Least Upper Bound type between two types, asserting compatability
    pub fn common(a: Type, b: Type) Type {
        if (a.kind == .poison or b.kind == .poison) return .atomic(.poison);
        if (a.kind == .noreturn) return b;
        if (b.kind == .noreturn) return a;

        if (a.eql(b)) return a;

        if (a.kind == .real and b.kind == .int or
            b.kind == .real and a.kind == .int)
        {
            return .atomic(.real);
        }

        unreachable;
    }
};

pub const Scope = struct {
    kind: Kind,

    pub const Kind = enum {
        /// the Root scope
        root,
        /// a LocalVar scope
        local_var,
        /// a Container
        container,
    };

    pub const builtins: std.StaticStringMap(Symbol) = .initComptime(.{
        .{ "int", Symbol.atomicType(.int) },
        .{ "real", Symbol.atomicType(.real) },
        .{ "bool", Symbol.atomicType(.bool) },
        .{ "str", Symbol.atomicType(.str) },
        .{ "type", Symbol.atomicType(.type) },
        .{ "void", Symbol.atomicType(.void) },
    });

    /// used for local var declarations as well as
    /// function parameters
    pub const LocalVar = struct {
        pub const base_kind: Kind = .local_var;

        base: Scope = .{ .kind = .local_var },
        parent: *Scope,
        /// if it was initialised with `var`
        is_var: bool,
        /// the identifier string
        ident: []const u8,
        symbol: Symbol,
    };

    pub const Container = struct {
        pub const base_kind: Kind = .container;

        base: Scope = .{ .kind = .container },
        parent: *Scope,
        /// an array of identifiers mapping to symbols
        decls: std.MultiArrayList(struct { []const u8, Symbol }),
    };

    pub const Root = struct {
        pub const base_kind: Kind = .root;
        base: Scope = .{ .kind = .root },
    };

    fn cast(base: *Scope, comptime T: type) *T {
        assert(base.kind == T.base_kind);

        return @alignCast(@fieldParentPtr("base", base));
    }

    pub fn parent(base: *Scope) ?*Scope {
        return switch (base.kind) {
            .root => null,
            .local_var => base.cast(LocalVar).parent,
            .container => base.cast(Container).parent,
        };
    }

    pub fn getSymbol(base: *Scope, ident: []const u8) ?Symbol {
        var maybe_scope: ?*Scope = base;

        if (builtins.get(ident)) |symbol| {
            return symbol;
        }

        while (maybe_scope) |scope| {
            switch (scope.kind) {
                .root => return null,
                .local_var => {
                    const local_var = scope.cast(LocalVar);
                    if (std.mem.eql(u8, ident, local_var.ident)) {
                        return local_var.symbol;
                    }
                },
                .container => {
                    const container = scope.cast(Container);
                    for (0..container.decls.len) |i| {
                        const item_ident = container.decls.items(.@"0")[i];
                        if (std.mem.eql(u8, ident, item_ident)) {
                            return container.decls.items(.@"1")[i];
                        }
                    }
                },
            }

            maybe_scope = scope.parent();
        }

        return null;
    }
};

fn addExtraStruct(s: *Self, value: anytype) Allocator.Error!ExtraIndex {
    const type_info = @typeInfo(@TypeOf(value)).@"struct";

    const result = s.extra_data.items.len;

    inline for (type_info.field_names) |field_name| {
        _ = try s.addExtra(@field(value, field_name));
    }

    return @fromBackingInt(@intCast(result));
}

fn addExtra(s: *Self, value: anytype) Allocator.Error!ExtraIndex {
    const extra: u32 = switch (@TypeOf(value)) {
        ExtraIndex,
        Type.Ref,
        => @backingInt(value),
        TokenIndex,
        => value,
        else => @compileError("not acceptable type for extra"),
    };

    try s.extra_data.append(s.gpa, extra);
    return @fromBackingInt(@intCast(s.extra_data.items.len - 1));
}

pub fn init(
    ast: *const Ast,
    gpa: Allocator,
    constants_arena: Allocator,
    scope_arena: Allocator,
    writer: *std.Io.Writer,
    diagnostics: *Diagnostics,
) Self {
    return .{
        .writer = writer,
        .stack_size = 0,
        .entry_fn = null,
        .allocated_regs = 0,
        .bytecode = .empty,
        .types = .empty,
        .types_data = .empty,
        .gpa = gpa,
        .constants = .empty,
        .constants_arena = constants_arena,
        .scope_arena = scope_arena,
        .ast = ast,
        .diagnositcs = diagnostics,
    };
}

const ReturnInfo = struct {
    return_type: Type.Ref,
    return_type_node: Node.Index,

    pub const dummy: ReturnInfo = .{
        .return_type = .poison,
        .return_type_node = undefined,
    };
};

fn getType(s: *Self, t: Type.Ref) Type {
    assert(t.isIdx());
    return s.types.get(@backingInt(t) - Type.Ref.static_len);
}

fn addType(s: *Self, t: Type) error{OutOfMemory}!Type.Ref {
    const result = s.types.len;
    try s.types.append(s.gpa, t);
    return .fromIdx(result);
}

fn typesEql(s: *Self, a: Type.Ref, b: Type.Ref) bool {
    if (a.isIdx() and b.isIdx()) {
        const a_data = s.getType(a);
        const b_data = s.getType(b);

        // TODO: non-atomic type equality
        _ = a_data;
        _ = b_data;
    }
    return a == b;
}

/// returns the Least Upper Bound type between two types, asserting compatability
fn commonType(s: *Self, a: Type.Ref, b: Type.Ref) Type.Ref {
    // TODO: non-atomic LUB types
    if (a == .poison or b == .poison) return .poison;
    if (a == .noreturn) return b;
    if (b == .noreturn) return a;

    if (s.typesEql(a, b)) return a;

    if (a == .real and b == .int or
        b == .real and a == .int)
    {
        return .real;
    }

    unreachable;
}

/// checks if two types can coerce into the same type
fn typesCompat(s: *Self, a: Type.Ref, b: Type.Ref) bool {
    // TODO: non-atomic type compatability
    if (a == .poison or b == .poison) return true;
    if (a == .noreturn or b == .noreturn) return true;
    if (s.typesEql(a, b)) return true;

    if (a == .real and b == .int or
        b == .real and a == .int)
    {
        return true;
    }

    return false;
}

fn emitError(s: *Self, data: Diagnostic.Data, span: Span) Error!void {
    try s.diagnositcs.add(.{ .level = .@"error", .data = data, .span = span });
}

pub fn addScope(s: *Self, comptime T: type, scope: T) Allocator.Error!*Scope {
    const scope_ptr = try s.scope_arena.create(T);
    scope_ptr.* = scope;
    return &scope_ptr.base;
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

/// creates the Vm.Value.Func and pushes it to the constants array
fn createBytecode(s: *Self, offset: usize) Error!usize {
    const bytecode = try s.constants_arena.create(Vm.Value.Func);

    try debug.debugBytecode(s.bytecode.items, offset, s.writer);
    try s.writer.writeByte('\n');

    bytecode.* = .{ .bytecode_offset = offset, .reg_file_size = s.stack_size };

    const result = s.constants.items.len;
    try s.constants.append(s.gpa, bytecode);
    return result;
}

pub fn genBytecode(s: *Self) Error!void {
    const root_node = s.ast.getNode(.root);

    var root_scope: Scope.Root = .{};
    var container_scope: Scope.Container = .{
        .parent = &root_scope.base,
        .decls = .empty,
    };
    defer container_scope.decls.deinit(s.gpa);

    for (s.ast.extraDataSlice(root_node.data.extra_range, Node.Index)) |node| {
        try s.genDecl(&container_scope.base, node);
    }

    if (s.diagnositcs.diagnostics.len > 0) return error.GenError;
}

fn genDecl(s: *Self, scope: *Scope, decl: Node.Index) Error!void {
    const node = s.ast.getNode(decl);
    switch (node.kind) {
        .func_decl => return s.genFuncDecl(scope, decl),
        .var_decl => {
            return s.emitError(
                .{ .direct_msg = "variable declarations at container scope not supported" },
                s.ast.tokenSpan(node.main_token),
            );
        },
        else => unreachable,
    }
}

fn genFuncDecl(s: *Self, scope: *Scope, decl: Node.Index) Error!void {
    const bytecode_offset = s.bytecode.items.len;

    const decl_node = s.ast.getNode(decl);

    const func_proto = s.ast.getNode(decl_node.data.node_and_node.@"0");

    const return_type = try s.genTypeExpr(scope, func_proto.data.node_and_extra.node);
    const block = decl_node.data.node_and_node.@"1";

    const return_info: ReturnInfo = .{
        .return_type = return_type,
        .return_type_node = func_proto.data.node_and_extra.node,
    };

    _ = try s.genBlock(scope, block, &return_info);

    if (s.last_emitted_op != .func_return) {
        try s.emitOp(.func_return);
    }

    const constant = try s.createBytecode(bytecode_offset);

    assert(scope.kind == .container);

    const ident = s.ast.tokenString(decl_node.main_token + 1);

    if (std.mem.eql(u8, "main", ident)) {
        s.entry_fn = constant;
    }

    const container = scope.cast(Scope.Container);
    try container.decls.append(s.gpa, .{
        s.ast.tokenString(decl_node.main_token + 1),
        .{
            .value = .{ .constant = constant },
            .type = try s.addType(.{
                .func = .{ .return_type = return_type },
            }),
        },
    });
}

fn genVarDecl(s: *Self, scope: *Scope, decl: Node.Index, return_info: *const ReturnInfo) Error!*Scope {
    const node = s.ast.getNode(decl);

    const var_reg = s.allocReg();

    const initial_type = try s.genExpr(scope, node.data.node_and_opt.@"0", return_info);
    var var_type = initial_type;

    if (node.data.node_and_opt.@"1".toOptional()) |type_expr| {
        const specified_type = try s.genTypeExpr(scope, type_expr);

        var_type = specified_type;

        if (!s.typesEql(specified_type, initial_type)) {
            try s.emitError(
                .{ .expected_type_because = .{
                    .expected = specified_type,
                    .because = type_expr,
                    .found = initial_type,
                } },
                s.ast.nodeSpan(node.data.node_and_opt.@"0"),
            );
        }
    }

    try s.emitOp(.store_to_reg);
    try s.emitVal(var_reg);

    return s.addScope(Scope.LocalVar, .{
        .parent = scope,
        .is_var = s.ast.tokenTag(node.main_token) == .keyword_var,
        .ident = s.ast.tokenString(node.main_token + 1),
        .symbol = .{
            .type = var_type,
            .value = .{ .reg = var_reg },
        },
    });
}

fn genBlock(s: *Self, base: *Scope, block: Node.Index, return_info: *const ReturnInfo) Error!Type.Ref {
    const node = s.ast.getNode(block);

    var scope = base;

    const start_regs = s.allocated_regs;

    const stmts = s.ast.extraDataSlice(node.data.extra_range, Node.Index);

    for (stmts) |stmt| {
        const stmt_node = s.ast.getNode(stmt);
        switch (stmt_node.kind) {
            .var_decl => scope = try s.genVarDecl(scope, stmt, return_info),
            else => _ = try s.genExpr(scope, stmt, return_info),
        }
    }

    s.allocated_regs = start_regs;

    return .void;
}

/// asserts the expression is a type and returns the contents
/// of the type expr
fn genTypeExpr(s: *Self, scope: *Scope, expr: Node.Index) Error!Type.Ref {
    const node = s.ast.getNode(expr);

    switch (node.kind) {
        .identifier => {
            const token_name = s.ast.tokenString(node.main_token);

            const symbol = scope.getSymbol(token_name) orelse {
                try s.emitError(
                    .{ .direct_msg = "Use of undeclared identifier" },
                    s.ast.tokenSpan(node.main_token),
                );
                return .poison;
            };

            if (!s.typesEql(symbol.type, .type)) {
                try s.emitError(.{ .expected_type = .{
                    .expected = .type,
                    .found = symbol.type,
                } }, s.ast.nodeSpan(expr));
                return .poison;
            }

            return symbol.value.type;
        },
        else => {
            try s.emitError(.{ .expected_type = .{
                .expected = .type,
                .found = try s.genExpr(scope, expr, &.dummy),
            } }, s.ast.nodeSpan(expr));
            return .poison;
        },
    }
}

/// returns the type of the expression
fn genExpr(s: *Self, scope: *Scope, expr: Node.Index, return_info: *const ReturnInfo) Error!Type.Ref {
    const node = s.ast.getNode(expr);
    return switch (node.kind) {
        .infix_op => try s.genBinOp(scope, node, return_info),
        .prefix_op => @panic("Prefix op not implemented yet"),
        .int_literal => try s.genInt(node),
        .identifier => {
            const token = s.ast.tokens.get(node.main_token);
            const name = s.ast.source[token.loc.start..token.loc.end];

            const symbol = scope.getSymbol(name) orelse {
                try s.emitError(
                    .{ .direct_msg = "Use of undeclared identifier" },
                    s.ast.tokenSpan(node.main_token),
                );
                return .poison;
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
                .type => {},
            }
            return symbol.type;
        },
        .block => try s.genBlock(scope, node.data.node, return_info),
        .string_literal => {
            const token_string = s.ast.tokenString(node.main_token);
            assert(token_string.len >= 2);
            assert(token_string[0] == '"');
            assert(token_string[token_string.len - 1] == '"');

            const string_splice = token_string[1 .. token_string.len - 1];

            // adds @sizeOf(usize) for the string length
            const string_ptr = try s.constants_arena.alloc(u8, string_splice.len + @sizeOf(usize));

            std.mem.writeInt(usize, string_ptr[0..@sizeOf(usize)], string_splice.len, .native);
            @memcpy(string_ptr[@sizeOf(usize)..], string_splice);

            const string_constant: u64 = @intCast(s.constants.items.len);
            try s.constants.append(s.gpa, string_ptr.ptr);

            try s.emitOp(.width64);
            try s.emitOp(.load_constant);
            try s.emitVal(string_constant);

            return .str;
        },
        .func_call => {
            const func_type = try s.genExpr(scope, node.data.node_and_extra.node, return_info);
            assert(func_type.isIdx());

            const func_data = s.types.get(func_type.toIdx());

            if (func_data != .func) {
                s.emitError(
                    .{ .expected_fn_type = .{
                        .found = func_type,
                    } },
                    s.ast.nodeSpan(node.data.node_and_extra.node),
                );
                return .poison;
            }

            try s.emitOp(.call);

            return func_data.func.return_type;
        },
        .@"return" => try s.genReturn(scope, expr, return_info),
        .var_decl => unreachable,
        .func_decl => unreachable,
        .func_proto => unreachable,
        .root => unreachable,
    };
}

fn genBinOp(s: *Self, scope: *Scope, node: Node, return_info: *const ReturnInfo) Error!Type.Ref {
    const start_regs = s.allocated_regs;

    const op: Opcode = switch (s.ast.tokenTag(node.main_token)) {
        .plus => .int_add,
        .minus => .int_sub,
        .asterisk => .int_mul,
        .slash => .int_div,
        else => unreachable,
    };

    var lhs_type: Type.Ref = undefined;
    var rhs_type: Type.Ref = undefined;

    const rhs = s.ast.getNode(node.data.node_and_node.@"1");
    if (rhs.kind == .int_literal) {
        // if rhs is literal we can use the imm version instead
        // subtracting 4 to non-imm int op results in imm [`@import("Vm.zig").Opcode`]
        const imm_op: Opcode = @fromBackingInt(@backingInt(op) - 4);

        lhs_type = try s.genExpr(scope, node.data.node_and_node.@"0", return_info);
        rhs_type = .int;

        try s.emitOp(imm_op);
        try s.emitIntFromToken(rhs.main_token);
    } else {
        rhs_type = try s.genExpr(scope, node.data.node_and_node.@"1", return_info);
        try s.emitOp(.store_to_reg);
        const rhs_reg = s.allocReg();
        try s.emitVal(rhs_reg);

        lhs_type = try s.genExpr(scope, node.data.node_and_node.@"0", return_info);

        try s.emitOp(op);
        try s.emitVal(rhs_reg);
    }

    s.allocated_regs = start_regs;

    if (!s.typesCompat(lhs_type, .int) or !s.typesCompat(rhs_type, .int)) {
        try s.emitError(
            .{ .incompatible_op_types = .{
                .lhs = node.data.node_and_node.@"0",
                .lhs_type = lhs_type,
                .rhs = node.data.node_and_node.@"1",
                .rhs_type = rhs_type,
            } },
            s.ast.tokenSpan(node.main_token),
        );

        return .poison;
    }

    return s.commonType(lhs_type, rhs_type);
}

fn genInt(s: *Self, node: Node) Error!Type.Ref {
    try s.emitOp(.load_int_imm);
    try s.emitIntFromToken(node.main_token);

    return .int;
}

fn genReturn(s: *Self, scope: *Scope, node: Node.Index, return_info: *const ReturnInfo) Error!Type.Ref {
    const node_data = s.ast.getNode(node);
    if (node_data.data.opt.toOptional()) |expr| {
        const return_type = try s.genExpr(scope, expr, return_info);

        if (!s.typesCompat(return_type, return_info.return_type)) {
            try s.emitError(
                .{ .incompatible_return_types = .{
                    .expected = return_info.return_type,
                    .return_type_node = return_info.return_type_node,
                    .found = return_type,
                } },
                s.ast.nodeSpan(expr),
            );
        }
    } else {
        if (return_info.return_type != .void) {
            try s.emitError(
                .{ .incompatible_return_types = .{
                    .expected = return_info.return_type,
                    .return_type_node = return_info.return_type_node,
                    .found = .void,
                } },
                s.ast.nodeSpan(node),
            );
        }
    }

    try s.emitOp(.func_return);

    return .noreturn;
}
