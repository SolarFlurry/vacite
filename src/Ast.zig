const std = @import("std");
const Allocator = std.mem.Allocator;

const BytecodeGen = @import("BytecodeGen.zig");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const Parser = @import("Parser.zig");
const Vm = @import("Vm.zig");
const BytecodeArray = Vm.BytecodeArray;

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
        ///   0: func_proto
        ///   1: body
        func_decl,
        /// main_token: `func`
        /// data: node
        ///   the return type
        func_proto,
        /// main_token: `let` or `var`
        /// data: node_and_opt
        ///   node: the intial expression
        ///   opt: and optional type
        var_decl,
        identifier,
        int_literal,
        /// main_token: the operator
        /// data: node_and_node
        ///    0: lhs
        ///    1: rhs
        infix_op,
        /// main_token: the operator
        /// data: node
        prefix_op,
        /// main_token: the l_brace
        /// data: extra_range
        ///    points to the statements
        block,
        /// main_token: `return`
        /// data: opt
        ///    optional return value
        @"return",
    };

    pub const Data = union {
        node: Index,
        opt: OptionalIndex,
        node_and_node: struct { Index, Index },
        node_and_opt: struct { Index, OptionalIndex },
        extra_and_node: struct { ExtraIndex, Index },
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
};

pub fn getNode(s: *const Ast, node: Node.Index) Node {
    return s.nodes.get(@backingInt(node));
}

pub fn tokenTag(s: *const Ast, token: TokenIndex) Token.Tag {
    return s.tokens.get(token).tag;
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

pub fn parse(gpa: Allocator, source: [:0]const u8, writer: *std.Io.Writer) (Parser.Error || error{WriteFailed})!Ast {
    var tokens: TokenList = .empty;

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
        .errors = .empty,
        .scratch = .empty,
    };
    errdefer {
        parser.tokens.deinit(gpa);
        parser.nodes.deinit(gpa);
        parser.extra_data.deinit(gpa);
    }
    defer {
        parser.scratch.deinit(gpa);
        parser.errors.deinit(gpa);
    }

    const result = parser.parseRoot();
    result catch |err| {
        if (err != error.ParseError) return err;
        for (parser.errors.items) |error_data| {
            try error_data.format(writer, source, parser.tokens);
        }

        return err;
    };

    return .{
        .source = source,
        .nodes = parser.nodes.toOwnedSlice(),
        .tokens = parser.tokens,
        .extra_data = try parser.extra_data.toOwnedSlice(gpa),
    };
}

pub fn bytecode(s: *Ast, gpa: Allocator) BytecodeGen.Error!BytecodeArray {
    var bytecode_gen: BytecodeGen = .{
        .stack_size = 0,
        .allocated_regs = 0,
        .bytecode = .empty,
        .gpa = gpa,
        .ast = s,
    };

    try bytecode_gen.genBytecode();

    return .{
        .bytecode = try bytecode_gen.bytecode.toOwnedSlice(gpa),
        .stack_size = bytecode_gen.stack_size,
    };
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

        try writer.print(
            "\x1b[36m.{s}\x1b[0m -> \x1b[33m'{s}'\x1b[0m\n",
            .{ @tagName(token.tag), s.source[token.loc.start..token.loc.end] },
        );
    }
}

fn printNode(s: *const Ast, writer: *std.Io.Writer, node_i: Node.Index, indent: u32) std.Io.Writer.Error!void {
    const node = s.getNode(node_i);

    try writer.splatBytesAll("  ", indent);
    try writer.print("\x1b[36m.{s}\x1b[0m", .{@tagName(node.kind)});

    switch (node.kind) {
        .root => unreachable,
        .infix_op => {
            try writer.print(" \x1b[32m'{s}'\x1b[0m:\n", .{s.tokenTag(node.main_token).lexeme()});
            try s.printNode(writer, node.data.node_and_node.@"0", indent + 1);
            try s.printNode(writer, node.data.node_and_node.@"1", indent + 1);
        },
        .int_literal => {
            const token = s.tokens.get(node.main_token);
            const str = s.source[token.loc.start..token.loc.end];
            try writer.print(" \x1b[31m{s}\x1b[0m\n", .{str});
        },
        .var_decl => {
            const ident = s.tokens.get(node.main_token + 1);
            try writer.print(" `{s}`:\n", .{s.source[ident.loc.start..ident.loc.end]});
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
            try writer.print(" `{s}`:\n", .{s.source[ident.loc.start..ident.loc.end]});
            try s.printNode(writer, node.data.node_and_node.@"0", indent + 1);
            try s.printNode(writer, node.data.node_and_node.@"1", indent + 1);
        },
        .identifier => unreachable,
        else => try writer.writeByte('\n'),
    }
}
