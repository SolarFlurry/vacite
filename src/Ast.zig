const std = @import("std");
const Allocator = std.mem.Allocator;

const BytecodeGen = @import("BytecodeGen.zig");
const Diagnostics = @import("Diagnostics.zig");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const Span = Lexer.Span;
const Parser = @import("Parser.zig");
const print = @import("pretty_print.zig").print;
const Vm = @import("Vm.zig");
const BytecodeArray = Vm.BytecodeArray;
const debug = @import("Vm/debug.zig");

const Ast = @This();

source: [:0]const u8,
nodes: NodeList.Slice,
tokens: TokenList.Slice,
extra_data: []u32,

pub const TokenList = std.MultiArrayList(Token);
pub const TokenIndex = u32;

pub const ExtraIndex = enum(u32) { _ };
pub const ExtraRange = struct {
    start: ExtraIndex,
    end: ExtraIndex,
};

pub const NodeList = std.MultiArrayList(Node);

pub const Node = struct {
    kind: Kind,
    data: Data,
    main_token: TokenIndex,

    pub const Kind = enum {
        /// an extra_range of all decls
        root,
        /// main_token: `func`
        /// data: node_and_node
        ///   node: func_proto
        ///   opt: block
        func_decl,
        /// main_token: `func`
        /// data: node_and_extra
        ///   node: the return type expr
        ///   extra: ExtraRange to param nodes
        func_proto,
        /// main_token: `let` or `var`
        /// data: node_and_opt
        ///   node: the initial expression
        ///   opt: the optional type expression
        var_decl,
        identifier,
        int_literal,
        string_literal,
        /// main_token: operator
        /// data: node_and_node
        ///    0: lhs
        ///    1: rhs
        infix_op,
        /// main_token: operator
        /// data: node
        prefix_op,
        /// main_token: `{`
        /// data: extra_range
        ///    points to the statements
        block,
        /// main_token: `return`
        /// data: opt
        ///    optional return value
        @"return",
        /// main_token: `(`
        /// data: node_and_extra
        ///    node: the function
        ///    extra: points to ExtraRange
        func_call,
    };

    pub const Data = union {
        node: Index,
        opt: OptionalIndex,
        node_and_node: struct { Index, Index },
        node_and_opt: struct { Index, OptionalIndex },
        node_and_extra: struct {
            node: Index,
            extra: ExtraIndex,
        },
        extra_range: ExtraRange,
    };

    pub const Index = enum(u32) {
        root = 0,
        _,

        pub fn toOptional(index: Index) OptionalIndex {
            return @fromBackingInt(@backingInt(index));
        }
    };

    pub const OptionalIndex = enum(u32) {
        root = 0,
        none = std.math.maxInt(u32),
        _,

        pub fn toOptional(optional: OptionalIndex) ?Index {
            if (optional == .none) return null;
            return @fromBackingInt(@backingInt(optional));
        }

        pub fn fromOptional(value: ?Index) OptionalIndex {
            if (value) |index| return index.toOptional();
            return .none;
        }
    };

    pub const Param = struct {
        ident: TokenIndex,
        type: Node.Index,
    };
};

pub fn getNode(s: *const Ast, node: Node.Index) Node {
    return s.nodes.get(@backingInt(node));
}

pub fn tokenTag(s: *const Ast, token: TokenIndex) Token.Tag {
    return s.tokens.items(.tag)[token];
}

pub fn tokenSpan(s: *const Ast, token: TokenIndex) Span {
    return s.tokens.items(.loc)[token];
}

pub fn tokenString(s: *const Ast, token: TokenIndex) []const u8 {
    const tok = s.tokens.get(token);
    return s.source[tok.loc.start..tok.loc.end];
}

/// returns the `Span` of the first line of an inner `Span`
pub fn getLine(s: *const Ast, span: Span) Span {
    var line_start: usize = span.start;
    var line_end: usize = span.start;
    while (line_start > 0 and s.source[line_start - 1] != '\n') line_start -= 1;
    while (line_end < s.source.len and s.source[line_end] != '\n') line_end += 1;

    return .{ .start = line_start, .end = line_end };
}

/// counts the number of newlines in a span
pub fn countLines(s: *const Ast, span: Span) usize {
    var count: usize = 0;
    for (s.source[span.start..span.end]) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

pub fn extraData(s: *const Ast, extra: ExtraIndex, comptime T: type) T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
        @field(result, field_name) = switch (field_type) {
            Node.Index,
            Node.OptionalIndex,
            ExtraIndex,
            => @fromBackingInt(@intCast(s.extra_data[@backingInt(extra) + i])),
            TokenIndex => s.extra_data[@backingInt(extra) + i],
            else => @compileError("unexpected field type: " ++ @typeName(field_type)),
        };
    }
    return result;
}

pub fn extraDataSlice(s: Ast, range: ExtraRange, comptime T: type) []const T {
    return @ptrCast(s.extra_data[@backingInt(range.start)..@backingInt(range.end)]);
}

pub fn parse(
    gpa: Allocator,
    source: [:0]const u8,
    writer: *std.Io.Writer,
    diagnostics: *Diagnostics,
) (Parser.Error || error{WriteFailed})!Ast {
    var tokens: TokenList = .empty;

    errdefer {
        tokens.deinit(gpa);
    }

    var lexer: Lexer = .init(source);
    while (true) {
        const token = lexer.next();
        try tokens.append(gpa, token);

        if (token.tag == .eof) break;
    }

    var parser: Parser = .{
        .source = source,
        .gpa = gpa,
        .tokens = tokens.toOwnedSlice(),
        .nodes = .empty,
        .tok_i = 0,
        .extra_data = .empty,
        .scratch = .empty,
        .diagnostics = diagnostics,
    };

    defer {
        parser.scratch.deinit(gpa);
    }

    const result = parser.parseRoot();
    var ast: Ast = .{
        .source = source,
        .nodes = parser.nodes.toOwnedSlice(),
        .tokens = parser.tokens,
        .extra_data = try parser.extra_data.toOwnedSlice(gpa),
    };

    errdefer {
        ast.nodes.deinit(gpa);
        ast.tokens.deinit(gpa);
        gpa.free(ast.extra_data);
    }

    result catch |err| {
        if (err != error.ParseError) return err;
        try diagnostics.reportAll(&ast, writer);
        return err;
    };

    return ast;
}

pub fn genBytecode(
    s: *Ast,
    gpa: Allocator,
    writer: *std.Io.Writer,
    diagnostics: *Diagnostics,
) BytecodeGen.Error!Vm {
    var constants_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

    var string_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer string_arena.deinit();

    var bytecode_gen: BytecodeGen = .{
        .writer = writer,
        .stack_size = 0,
        .allocated_regs = 0,
        .bytecode = .empty,
        .gpa = gpa,
        .constants = .empty,
        .constants_arena = constants_arena.allocator(),
        .symbol_table = .init(),
        .ast = s,
        .diagnositcs = diagnostics,
    };
    defer bytecode_gen.symbol_table.deinit(gpa);

    bytecode_gen.genBytecode() catch |err| {
        bytecode_gen.constants.deinit(gpa);
        return err;
    };

    var vm: Vm = .{
        .arena = constants_arena,
        .constants = try constants_arena.allocator().dupe(*const anyopaque, bytecode_gen.constants.items),
        .gpa = gpa,
        .stack = .empty,
        .fp = 0,
        .pc = 0,
        .acc = undefined,
    };

    bytecode_gen.constants.deinit(gpa);

    const bytecode_ptr: [*]const u8 = @ptrCast(vm.constants[
        (bytecode_gen.symbol_table.getSymbol("main") orelse {
            try diagnostics.add(.{ .level = .@"error", .data = .no_main_func, .span = .{ .start = 0, .end = 0 } });
            return error.GenError;
        }).value.constant
    ]);

    const bytecode = Vm.getBytecodeArrayFromPtr(bytecode_ptr);

    try vm.pushStackFrame(bytecode.bytecode, bytecode.stack_size);

    return vm;
}

pub fn deinit(s: *Ast, gpa: std.mem.Allocator) void {
    gpa.free(s.extra_data);
    s.tokens.deinit(gpa);
    s.nodes.deinit(gpa);
}

pub fn format(s: *const Ast, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try s.printTokens(writer);

    try writer.writeByte('\n');

    const root_node = s.nodes.get(0);
    const decls = s.extraDataSlice(root_node.data.extra_range, Node.Index);

    for (decls) |decl| {
        try s.printNode(writer, decl, 0);
    }
}

fn printTokens(s: *const Ast, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (0..s.tokens.len) |i| {
        const token = s.tokens.get(i);

        try print(
            writer,
            "<d>.<0c>{s}<0> ->> <y>'{s}'<0>\n",
            .{ @tagName(token.tag), s.source[token.loc.start..token.loc.end] },
        );
    }
}

fn printNode(s: *const Ast, writer: *std.Io.Writer, node_i: Node.Index, indent: u32) std.Io.Writer.Error!void {
    const node = s.getNode(node_i);

    try writer.splatBytesAll("  ", indent);
    try print(writer, "<d>.<0c>{s}<0>", .{@tagName(node.kind)});

    switch (node.kind) {
        .root => unreachable,
        .infix_op => {
            try print(writer, " <y>'{s}'<0>:\n", .{s.tokenString(node.main_token)});
            try s.printNode(writer, node.data.node_and_node.@"0", indent + 1);
            try s.printNode(writer, node.data.node_and_node.@"1", indent + 1);
        },
        .int_literal => {
            const token = s.tokens.get(node.main_token);
            const str = s.source[token.loc.start..token.loc.end];
            try print(writer, " <r>{s}<0>\n", .{str});
        },
        .var_decl => {
            const ident = s.tokens.get(node.main_token + 1);
            try print(writer, " `{s}`:\n", .{s.source[ident.loc.start..ident.loc.end]});
            try s.printNode(writer, node.data.node_and_opt.@"0", indent + 1);
        },
        .@"return" => {
            if (node.data.opt.toOptional()) |return_expr| {
                try writer.writeAll(":\n");
                try s.printNode(writer, return_expr, indent + 1);
                return;
            }
            try writer.writeByte('\n');
        },
        .block => {
            try writer.writeByte('\n');
            const stmts = s.extraDataSlice(node.data.extra_range, Node.Index);
            for (stmts) |stmt| {
                try s.printNode(writer, stmt, indent + 1);
            }
        },
        .func_decl => {
            const ident = s.tokens.get(node.main_token + 1);
            try print(writer, " `{s}`:\n", .{s.source[ident.loc.start..ident.loc.end]});
            try s.printNode(writer, node.data.node_and_node.@"0", indent + 1);
            try s.printNode(writer, node.data.node_and_node.@"1", indent + 1);
        },
        .identifier => {
            const ident = s.tokens.get(node.main_token);
            try print(writer, " `{s}`\n", .{s.source[ident.loc.start..ident.loc.end]});
        },
        else => try writer.writeByte('\n'),
    }
}
