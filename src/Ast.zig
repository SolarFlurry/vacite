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
extra_data: []u8,

pub const TokenList = std.MultiArrayList(Token);
pub const TokenIndex = u32;

pub const ExtraIndex = enum(u32) { _ };

pub const NodeList = std.MultiArrayList(Node);

pub const Node = struct {
    kind: Kind,
    data: Data,
    main_token: TokenIndex,

    pub const Kind = enum {
        root,
        func_decl,
        identifier,
        int_literal,
        bin_op,
    };

    pub const Data = union {
        node: Index,
        node_and_node: struct { Index, Index },
        extra_and_node: struct { ExtraIndex, Index },
        extra_range: struct { start: ExtraIndex, end: ExtraIndex },
    };

    pub const Index = enum(u32) {
        root = 0,
        _,
    };
};

pub fn getNode(s: *const Ast, node: Node.Index) Node {
    return s.nodes.get(@backingInt(node));
}

pub fn tokenTag(s: *const Ast, token: TokenIndex) Token.Tag {
    return s.tokens.get(token).tag;
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
    };
    errdefer {
        parser.tokens.deinit(gpa);
        parser.nodes.deinit(gpa);
        parser.extra_data.deinit(gpa);
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
    try s.printNode(writer, root_node.data.node, 0);
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

    try writer.splatBytesAll("   ", indent);
    try writer.print("\x1b[36m.{s}\x1b[0m", .{@tagName(node.kind)});

    switch (node.kind) {
        .root => unreachable,
        .bin_op => {
            try writer.print(" \x1b[32m'{s}'\x1b[0m:\n", .{s.tokenTag(node.main_token).lexeme()});
            try s.printNode(writer, node.data.node_and_node.@"0", indent + 1);
            try s.printNode(writer, node.data.node_and_node.@"1", indent + 1);
        },
        .int_literal => {
            const token = s.tokens.get(node.main_token);
            const str = s.source[token.loc.start..token.loc.end];
            try writer.print(" \x1b[31m{s}\x1b[0m\n", .{str});
        },
        .identifier => unreachable,
        .func_decl => unreachable,
    }
}
