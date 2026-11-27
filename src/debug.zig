const std = @import("std");

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const print = @import("pretty_print.zig").print;
const Vm = @import("Vm.zig");
const BytecodeArray = Vm.BytecodeArray;
const Opcode = Vm.Opcode;

pub fn debugAst(s: *const Ast, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeByte('\n');

    const root_node = s.nodes.get(0);
    const decls = s.extraDataSlice(root_node.data.extra_range, Node.Index);

    for (decls) |decl| {
        try printNode(s, writer, decl, 0);
    }
}

pub fn debugTokens(s: *const Ast, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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
            try printNode(s, writer, node.data.node_and_node.@"0", indent + 1);
            try printNode(s, writer, node.data.node_and_node.@"1", indent + 1);
        },
        .int_literal => {
            const token = s.tokens.get(node.main_token);
            const str = s.source[token.loc.start..token.loc.end];
            try print(writer, " <r>{s}<0>\n", .{str});
        },
        .var_decl => {
            const ident = s.tokens.get(node.main_token + 1);
            try print(writer, " `{s}`:\n", .{s.source[ident.loc.start..ident.loc.end]});
            try printNode(s, writer, node.data.node_and_opt.@"0", indent + 1);
        },
        .@"return" => {
            if (node.data.opt.toOptional()) |return_expr| {
                try writer.writeAll(":\n");
                try printNode(s, writer, return_expr, indent + 1);
                return;
            }
            try writer.writeByte('\n');
        },
        .block => {
            try writer.writeByte('\n');
            const stmts = s.extraDataSlice(node.data.extra_range, Node.Index);
            for (stmts) |stmt| {
                try printNode(s, writer, stmt, indent + 1);
            }
        },
        .func_decl => {
            const ident = s.tokens.get(node.main_token + 1);
            try print(writer, " `{s}`:\n", .{s.source[ident.loc.start..ident.loc.end]});
            try printNode(s, writer, node.data.node_and_node.@"0", indent + 1);
            try printNode(s, writer, node.data.node_and_node.@"1", indent + 1);
        },
        .identifier => {
            const ident = s.tokens.get(node.main_token);
            try print(writer, " `{s}`\n", .{s.source[ident.loc.start..ident.loc.end]});
        },
        else => try writer.writeByte('\n'),
    }
}

pub fn debugBytecode(s: []const u8, instrs_offset: usize, writer: *std.Io.Writer) !void {
    var i: usize = instrs_offset;

    while (i < s.len) {
        try writer.print("{d: >4} | ", .{i});

        var opcode: Opcode = @fromBackingInt(@intCast(s[i]));
        const width: u8 = switch (opcode) {
            .width16 => 2,
            .width32 => 3,
            .width64 => 4,
            else => 1,
        };

        if (width > 1) {
            i += 1;
            opcode = @fromBackingInt(@intCast(s[i]));
        }

        const instr = opcode.asInstr();
        const instr_length = getInstrLength(instr, width);

        for (0..instr_length) |byte_offset| {
            try writer.print("{x:0>2} ", .{s[i + byte_offset]});
        }
        try writer.splatBytesAll("   ", 10 - instr_length);

        switch (width) {
            inline 1...4 => |w| {
                try writer.writeAll(.{ "", "w16_", "w32_", "w64_" }[w - 1]);

                switch (instr) {
                    .store_to_reg => try writer.print("star : r{d} = acc", .{readInt(s, i + 1, w)}),
                    .load_from_reg => try writer.print("ldra : acc = r{d}", .{readInt(s, i + 1, w)}),
                    .load_int_imm => try writer.print("ldia : acc = {d}", .{readInt(s, i + 1, w)}),
                    .load_constant => try writer.print("ldca : acc = c{d}", .{readInt(s, i + 1, w)}),
                    .call => try writer.writeAll("call"),
                    .func_return => try writer.writeAll("ret"),
                    .int_add_imm => try writer.print("iaddi : acc += {d}", .{readInt(s, i + 1, w)}),
                    .int_sub_imm => try writer.print("isubi : acc -= {d}", .{readInt(s, i + 1, w)}),
                    .int_mul_imm => try writer.print("imuli : acc *= {d}", .{readInt(s, i + 1, w)}),
                    .int_div_imm => try writer.print("idivi : acc /= {d}", .{readInt(s, i + 1, w)}),
                    .int_add => try writer.print("iadd : acc += r{d}", .{readInt(s, i + 1, w)}),
                    .int_sub => try writer.print("isub : acc -= r{d}", .{readInt(s, i + 1, w)}),
                    .int_mul => try writer.print("imul : acc *= r{d}", .{readInt(s, i + 1, w)}),
                    .int_div => try writer.print("idiv : acc /= r{d}", .{readInt(s, i + 1, w)}),
                    .str_write => try writer.writeAll("write"),
                }
            },
            else => unreachable,
        }

        try writer.writeByte('\n');

        i += instr_length;
    }
}

fn getInstrLength(instr: Opcode.Instr, width: u8) usize {
    switch (instr) {
        .str_write, .func_return, .call => return 1,
        .load_int_imm,
        .load_constant,
        .store_to_reg,
        .load_from_reg,
        .int_add_imm,
        .int_sub_imm,
        .int_mul_imm,
        .int_div_imm,
        .int_add,
        .int_sub,
        .int_mul,
        .int_div,
        => return 1 + (@as(usize, 1) << @intCast(width - 1)),
    }
}

fn readInt(bytes: []const u8, start: usize, comptime int_width: u8) @Int(.unsigned, 1 << int_width + 2) {
    return std.mem.readInt(@Int(.unsigned, 1 << int_width + 2), @ptrCast(bytes[start .. start + int_width]), .native);
}

fn opOneImm(
    name: []const u8,
    s: []const u8,
    writer: *std.Io.Writer,
    i: usize,
    comptime width: u8,
) !void {
    const immediate = readInt(s, i + 1, width);

    try writer.print("{s} #{d}", .{ name, immediate });
}

fn opOneReg(
    name: []const u8,
    s: []const u8,
    writer: *std.Io.Writer,
    i: usize,
    comptime width: u8,
) !void {
    const reg = readInt(s, i + 1, width);

    try writer.print("{s} r{d}", .{ name, reg });
}
