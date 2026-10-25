const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const TokenIndex = Ast.TokenIndex;
const Node = Ast.Node;
const ExtraIndex = Ast.ExtraIndex;
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;

const Parser = @This();

gpa: Allocator,
source: [:0]const u8,
tokens: Ast.TokenList.Slice,
extra_data: std.ArrayList(u8),
tok_i: TokenIndex,
nodes: Ast.NodeList,
errors: std.ArrayList(ParseError),

const ParseError = struct {
    kind: Kind,
    token: TokenIndex,

    const Kind = enum(u8) {
        generic_token,
    };
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

    const node = try p.parseExpr();
    p.nodes.items(.data)[0] = .{ .node = node };

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

fn addExtra(p: *Parser, value: anytype) Allocator.Error!ExtraIndex {
    const result = p.extra_data.items.len;
    try p.extra_data.appendSlice(p.gpa, std.mem.asBytes(&value));
    return result;
}

fn parseContainerMembers(p: *Parser) Error!void {
    while (true) {
        switch (p.tokenTag(p.tok_i)) {
            .keyword_let,
            .keyword_fun,
            => try p.parseDecl(),
            else => return p.failError(.generic_token),
        }
    }
}

fn parseDecl(p: *Parser) Error!void {
    const is_fn = try p.parseFnProto();

    if (is_fn) |fn_proto| {
        _ = fn_proto;
    }
}

fn parseFnProto(p: *Parser) Error!?Node.Index {
    const fn_token = p.eatToken(.keyword_fun) orelse return null;

    const func_node_idx = try p.reserveNode();

    _ = p.eatToken(.identifier);
    _ = p.eatToken(.l_paren);
    _ = p.eatToken(.r_paren);

    // p.parseTypeExpr

    return p.setNode(func_node_idx, .{
        .token = fn_token,
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

fn parseExpr(p: *Parser) Error!Node.Index {
    return p.parseExprPrecedence(.bottom);
}

fn parseExprPrecedence(p: *Parser, min_prec: OperInfo.Prec) Error!Node.Index {
    var node = try p.parsePrimaryExpr();

    while (true) {
        const tok_tag = p.tokenTag(p.tok_i);
        const info = oper_table[@backingInt(tok_tag)];

        const rel = info.prec.cmp(min_prec);

        if (rel == .lt or rel == .eq) break;

        const oper_token = p.nextToken();

        const rhs = try p.parseExprPrecedence(info.prec);

        node = try p.addNode(.{
            .kind = .bin_op,
            .main_token = oper_token,
            .data = .{ .node_and_node = .{ node, rhs } },
        });
    }

    return node;
}

fn parsePrimaryExpr(p: *Parser) Error!Node.Index {
    const node_kind: Node.Kind = switch (p.tokenTag(p.tok_i)) {
        .identifier => .identifier,
        .int_literal => .int_literal,
        else => return p.failError(.generic_token),
    };

    return p.addNode(.{
        .main_token = p.nextToken(),
        .kind = node_kind,
        .data = undefined,
    });
}
