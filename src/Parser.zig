const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const TokenIndex = Ast.TokenIndex;
const Node = Ast.Node;
const ExtraIndex = Ast.ExtraIndex;
const ExtraRange = Ast.ExtraRange;
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;

const Parser = @This();

gpa: Allocator,
source: [:0]const u8,
tokens: Ast.TokenList.Slice,
scratch: std.ArrayList(Node.Index),
extra_data: std.ArrayList(u32),
tok_i: TokenIndex,
nodes: Ast.NodeList,
errors: std.ArrayList(ParseError),

const ParseError = struct {
    kind: Kind,
    token: TokenIndex,

    const Kind = enum {
        generic_token,
        unexpected_eof,
        expected_expr,
        expected_decl,
        expected_semicolon,
    };

    pub fn format(s: ParseError, writer: *std.Io.Writer, source: [:0]const u8, tokens: Ast.TokenList.Slice) std.Io.Writer.Error!void {
        try writer.writeAll("\x1b[31mError\x1b[0m: ");
        const token = tokens.get(s.token);
        const token_string = source[token.loc.start..token.loc.end];
        switch (s.kind) {
            .generic_token => try writer.print("Bad token '{s}'\n", .{token_string}),
            .unexpected_eof => try writer.writeAll("Unexpected EOF\n"),
            .expected_expr => try writer.print("Unexpected '{s}', expected an expression\n", .{token_string}),
            .expected_decl => try writer.print("Unexpected '{s}', expected a declaration\n", .{token_string}),
            .expected_semicolon => try writer.print("Unexpected '{s}', expected a semicolon\n", .{token_string}),
        }
    }
};

pub const Error = error{ParseError} || Allocator.Error;

fn failError(p: *Parser, kind: ParseError.Kind) Error {
    @branchHint(.cold);
    try p.errors.append(p.gpa, .{
        .kind = kind,
        .token = p.tok_i,
    });
    return error.ParseError;
}

pub fn parseRoot(p: *Parser) Error!void {
    try p.nodes.append(p.gpa, .{
        .data = .{ .node = @fromBackingInt(@intCast(0)) },
        .main_token = p.tok_i,
        .kind = .root,
    });

    const decls = try p.parseContainerMembers();
    p.nodes.items(.data)[0] = .{ .extra_range = decls };

    // try p.parseContainerMembers();
}

fn nextToken(p: *Parser) TokenIndex {
    const result = p.tok_i;
    p.tok_i += 1;
    return result;
}

fn tokenTag(p: *Parser, tok: TokenIndex) Token.Tag {
    return p.tokens.get(tok).tag;
}

fn expectToken(p: *Parser, expected: Lexer.Token.Tag) Error!TokenIndex {
    if (p.tokens.get(p.tok_i).tag != expected) {
        return p.failError(.generic_token);
    }
    return p.nextToken();
}

fn eatToken(p: *Parser, expected: Token.Tag) ?TokenIndex {
    if (p.tokenTag(p.tok_i) != expected) return null;
    return p.nextToken();
}

fn addNode(p: *Parser, elem: Ast.Node) Allocator.Error!Node.Index {
    const result: Node.Index = @fromBackingInt(@intCast(p.nodes.len));
    try p.nodes.append(p.gpa, elem);
    return result;
}

fn reserveNode(p: *Parser) Allocator.Error!usize {
    try p.nodes.resize(p.gpa, p.nodes.len + 1);
    return p.nodes.len - 1;
}

fn setNode(p: *Parser, idx: usize, node: Node) Node.Index {
    p.nodes.set(idx, node);
    return @fromBackingInt(@intCast(idx));
}

fn currentExtraIndex(p: *Parser) ExtraIndex {
    return @fromBackingInt(@intCast(p.extra_data.items.len));
}

fn addExtraStruct(p: *Parser, value: anytype) Allocator.Error!ExtraIndex {
    const type_info = @typeInfo(@TypeOf(value)).@"struct";

    const result = p.extra_data.items.len;

    inline for (type_info.field_names) |field_name| {
        _ = try p.addExtra(@field(value, field_name));
    }

    return @fromBackingInt(@intCast(result));
}

fn addExtra(p: *Parser, value: anytype) Allocator.Error!ExtraIndex {
    const extra: u32 = switch (@TypeOf(value)) {
        ExtraIndex,
        Node.Index,
        => @backingInt(value),
        TokenIndex,
        => value,
        else => @compileError("not acceptable type for extra"),
    };

    try p.extra_data.append(p.gpa, extra);
    return @fromBackingInt(@intCast(p.extra_data.items.len - 1));
}

fn listToSpan(p: *Parser, nodes: []const Node.Index) Allocator.Error!ExtraRange {
    try p.extra_data.appendSlice(p.gpa, @ptrCast(nodes));
    return .{
        .start = @fromBackingInt(@intCast(p.extra_data.items.len - nodes.len)),
        .end = @fromBackingInt(@intCast(p.extra_data.items.len)),
    };
}

fn parseContainerMembers(p: *Parser) Error!ExtraRange {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        const node = switch (p.tokenTag(p.tok_i)) {
            .keyword_let,
            .keyword_func,
            => try p.parseDecl(),
            .eof, .r_brace => break,
            else => return p.failError(.expected_decl),
        };

        try p.scratch.append(p.gpa, node);
    }

    return p.listToSpan(p.scratch.items[scratch_top..]);
}

fn parseDecl(p: *Parser) Error!Node.Index {
    const start_token = p.tok_i;
    const is_fn = try p.parseFnProto();

    if (is_fn) |fn_proto| {
        const block = try p.parseBlock();
        return p.addNode(.{
            .main_token = start_token,
            .data = .{ .node_and_node = .{ fn_proto, block } },
            .kind = .func_decl,
        });
    }

    return p.parseVarDecl();
}

fn parseVarDecl(p: *Parser) Error!Node.Index {
    const decl_token = p.eatToken(.keyword_let).?;
    _ = try p.expectToken(.identifier);
    if (p.tokenTag(p.tok_i) != .equal) {
        // TODO: typed variable declerations
    }

    _ = try p.expectToken(.equal);
    const initial_value = try p.expectExpr();

    return p.addNode(.{
        .kind = .var_decl,
        .main_token = decl_token,
        .data = .{ .node_and_opt = .{ initial_value, .none } },
    });
}

fn parseFnProto(p: *Parser) Error!?Node.Index {
    const fn_token = p.eatToken(.keyword_func) orelse return null;

    const func_node_idx = try p.reserveNode();

    _ = p.eatToken(.identifier);
    _ = p.eatToken(.l_paren);
    _ = p.eatToken(.r_paren);

    const return_type = try p.parseTypeExpr() orelse return p.failError(.expected_expr);

    return p.setNode(func_node_idx, .{
        .main_token = fn_token,
        .data = .{ .node = return_type },
        .kind = .func_proto,
    });
}

const OperInfo = struct {
    prec: Prec,

    const Prec = enum(u8) {
        bottom,

        arithmetic_sum,
        arithmetic_prod,

        top,

        pub fn cmp(lhs: Prec, rhs: Prec) std.math.Order {
            return std.math.order(@backingInt(lhs), @backingInt(rhs));
        }
    };
};

const oper_table = std.enums.directEnumArrayDefault(Token.Tag, OperInfo, .{ .prec = .bottom }, 0, .{
    .plus = .{ .prec = .arithmetic_sum },
    .minus = .{ .prec = .arithmetic_sum },
    .asterisk = .{ .prec = .arithmetic_prod },
    .slash = .{ .prec = .arithmetic_prod },
});

fn expectExpr(p: *Parser) Error!Node.Index {
    return try p.parseExpr() orelse return p.failError(.expected_expr);
}

fn parseExpr(p: *Parser) Error!?Node.Index {
    return p.parseExprPrecedence(.bottom);
}

fn parseExprPrecedence(p: *Parser, min_prec: OperInfo.Prec) Error!?Node.Index {
    var node = try p.parsePrimaryExpr() orelse return null;

    while (true) {
        const tok_tag = p.tokenTag(p.tok_i);
        const info = oper_table[@backingInt(tok_tag)];

        const rel = info.prec.cmp(min_prec);

        if (rel == .lt or rel == .eq) break;

        const oper_token = p.nextToken();

        const rhs = try p.parseExprPrecedence(info.prec) orelse return null;

        node = try p.addNode(.{
            .kind = .infix_op,
            .main_token = oper_token,
            .data = .{ .node_and_node = .{ node, rhs } },
        });
    }

    return node;
}

fn parsePrefixExpr(p: *Parser) Error!?Node.Index {
    switch (p.tokenTag(p.tok_i)) {
        .minus,
        .bang,
        => {},
        else => return p.parsePrimaryExpr(),
    }

    return p.addNode(.{
        .main_token = p.nextToken(),
        .kind = .prefix_op,
        .data = .{ .node = p.parsePrefixExpr() },
    });
}

fn parsePrimaryExpr(p: *Parser) Error!?Node.Index {
    return switch (p.tokenTag(p.tok_i)) {
        .keyword_return => try p.addNode(.{
            .main_token = p.nextToken(),
            .kind = .@"return",
            .data = .{ .opt = .fromOptional(try p.parseExpr()) },
        }),
        else => p.parseTypeExpr(),
    };
}

fn parseTypeExpr(p: *Parser) Error!?Node.Index {
    return p.parseSuffixExpr();
}

fn parseSuffixExpr(p: *Parser) Error!?Node.Index {
    var operand = try p.parsePrimaryTypeExpr() orelse return null;
    while (true) {
        const expr = switch (p.tokenTag(p.tok_i)) {
            .l_brack => @panic("index not implemented yet"),
            .l_paren => blk: {
                const token = p.tok_i;

                const exprs = try p.parseFuncCallList();
                const extra = try p.addExtraStruct(exprs);

                break :blk try p.addNode(.{
                    .data = .{ .node_and_extra = .{
                        .node = operand,
                        .extra = extra,
                    } },
                    .kind = .func_call,
                    .main_token = token,
                });
            },
            else => break,
        };

        operand = expr;
    }

    return operand;
}

fn parseFuncCallList(p: *Parser) Error!ExtraRange {
    _ = p.eatToken(.l_paren);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (p.tokenTag(p.tok_i) != .r_paren and p.tokenTag(p.tok_i) != .eof) {
        try p.scratch.append(p.gpa, try p.parseExpr() orelse return error.ParseError);

        if (p.tokenTag(p.tok_i) != .r_paren) _ = try p.expectToken(.comma);
    }

    _ = try p.expectToken(.r_paren);
    return try p.listToSpan(p.scratch.items[scratch_top..]);
}

fn parsePrimaryTypeExpr(p: *Parser) Error!?Node.Index {
    const node_kind: Node.Kind = switch (p.tokenTag(p.tok_i)) {
        .identifier => .identifier,
        .int_literal => .int_literal,
        .string_literal => .string_literal,
        else => return null,
    };

    return try p.addNode(.{
        .main_token = p.nextToken(),
        .kind = node_kind,
        .data = undefined,
    });
}

fn parseBlock(p: *Parser) Error!Node.Index {
    const start_token = p.eatToken(.l_brace).?;

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        const node = switch (p.tokenTag(p.tok_i)) {
            .r_brace => break,
            .keyword_let,
            .keyword_var,
            => try p.parseVarDecl(),
            .eof => return p.failError(.unexpected_eof),
            else => try p.expectExpr(),
        };

        try p.scratch.append(p.gpa, node);

        if (p.tokenTag(p.tok_i - 1) != .r_brace) {
            _ = p.eatToken(.semicolon) orelse return p.failError(.expected_semicolon);
        }
    }

    _ = try p.expectToken(.r_brace);

    return p.addNode(.{
        .kind = .block,
        .main_token = start_token,
        .data = .{ .extra_range = try p.listToSpan(p.scratch.items[scratch_top..]) },
    });
}
