const std = @import("std");

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const BytecodeGen = @import("BytecodeGen.zig");
const Symbol = BytecodeGen.Symbol;
const Type = BytecodeGen.Type;
pub const Builder = @import("Diagnostics/Builder.zig");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const Span = Lexer.Span;
const pretty_print = @import("pretty_print.zig");
const print = pretty_print.print;
const printA = pretty_print.allocPrint;

const Diagnostics = @This();
gpa: std.mem.Allocator,
diagnostics: std.MultiArrayList(Diagnostic),
arena: std.heap.ArenaAllocator,

pub fn init(gpa: std.mem.Allocator) Diagnostics {
    return .{
        .arena = .init(std.heap.page_allocator),
        .gpa = gpa,
        .diagnostics = .empty,
    };
}

pub fn deinit(s: *Diagnostics) void {
    s.diagnostics.deinit(s.gpa);
    s.arena.deinit();
}

pub fn build(s: *Diagnostics) Builder {
    return .{
        .diagnostics = s,
    };
}

fn tokenString(ast: *const Ast, tok: Ast.TokenIndex) []const u8 {
    if (ast.tokenTag(tok) == .eof) return "\x1b[3;34m(eof)\x1b[0;33m";
    return ast.tokenString(tok);
}

pub const Diagnostic = struct {
    level: Level,
    span: Span,
    data: Data,

    pub const Label = struct {
        message: []const u8,
        span: Span,
    };

    pub const Level = enum(u8) {
        @"error",
        warning,
        hint,
    };

    pub const Data = union(enum(u8)) {
        direct_msg: []const u8,
        unexpected_token: Ast.TokenIndex,
        expected_token: struct {
            unexpected: Token.Tag,
            expected: Token.Tag,
        },
        expected_expr: Token.Tag,
        expected_decl: Token.Tag,
        expected_closing: struct {
            expected: Token.Tag,
            prev: TokenIndex,
        },
        no_main_func: void,
        incompatible_op_types: struct {
            lhs: Node.Index,
            lhs_type: Type.Ref,
            rhs: Node.Index,
            rhs_type: Type.Ref,
        },
        incompatible_return_types: struct {
            expected: Type.Ref,
            return_type_node: Node.Index,
            found: Type.Ref,
        },
        incompatible_if_branch_types: struct {
            then: Node.Index,
            then_type: Type.Ref,
            @"else": Node.Index,
            else_type: Type.Ref,
        },
        expected_type: struct {
            expected: Type.Ref,
            found: Type.Ref,
        },
        expected_type_because: struct {
            expected: Type.Ref,
            because: Node.Index,
            found: Type.Ref,
        },
        expected_fn_type: struct {
            found: Type.Ref,
        },
    };

    pub fn write(
        s: *const Diagnostic,
        arena: std.mem.Allocator,
        ast: *const Ast,
        writer: *std.Io.Writer,
    ) error{ WriteFailed, OutOfMemory }!void {
        var labels_buffer: [4]Label = undefined;
        var labels: std.ArrayList(Label) = .initBuffer(&labels_buffer);

        switch (s.level) {
            .@"error" => try print(writer, "<rB>[Error]<0> ", .{}),
            .warning => try print(writer, "<yB>[Warning]<0> ", .{}),
            else => try writer.writeAll("[Diagnostic] "),
        }

        switch (s.data) {
            .direct_msg => |d| try print(writer, "{s}\n", .{d}),
            .unexpected_token => |d| try print(writer, "Unexpected <y>'{s}'<0>\n", .{tokenString(ast, d)}),
            .expected_token => |d| try print(writer, "Expected {s}, got {s}\n", .{ d.expected.describe(), d.unexpected.describe() }),
            .expected_expr => |d| try print(writer, "Expected an expression, got {s}\n", .{d.describe()}),
            .expected_decl => |d| try print(writer, "Expected a declaration, got {s}\n", .{d.describe()}),
            .expected_closing => |d| {
                try print(writer, "Expected matching closing {s}\n", .{d.expected.describe()});

                labels.appendAssumeCapacity(.{
                    .message = try arena.print("Expected {s} here", .{d.expected.describe()}),
                    .span = s.span,
                });

                labels.appendAssumeCapacity(.{
                    .message = try arena.print("Matching {s}", .{ast.tokenTag(d.prev).describe()}),
                    .span = ast.tokenSpan(d.prev),
                });
            },
            .no_main_func => try print(writer, "No 'main' function\n", .{}),
            .incompatible_op_types => |d| {
                const lhs_type_string = d.lhs_type.toString();
                const rhs_type_string = d.rhs_type.toString();

                try print(writer, "Incompatible types <r>{s}<0> and <r>{s}<0>\n", .{ lhs_type_string, rhs_type_string });

                const lhs_span = ast.nodeSpan(d.lhs);
                const rhs_span = ast.nodeSpan(d.rhs);

                labels.appendAssumeCapacity(.{
                    .message = try printA(arena, "LHS has type <r>{s}<0>", .{lhs_type_string}),
                    .span = lhs_span,
                });

                labels.appendAssumeCapacity(.{
                    .message = try printA(arena, "RHS has type <r>{s}<0>", .{rhs_type_string}),
                    .span = rhs_span,
                });
            },
            .expected_type => |d| {
                try print(writer, "Expected type <r>{s}<0>, found <r>{s}<0>\n", .{ d.expected.toString(), d.found.toString() });

                labels.appendAssumeCapacity(.{
                    .message = try printA(arena, "This value has type <r>{s}<0>", .{d.found.toString()}),
                    .span = s.span,
                });
            },
            .incompatible_return_types => |d| {
                const expected_string = d.expected.toString();
                const found_string = d.found.toString();

                try print(writer, "Incompatible return types <r>{s}<0> and <r>{s}<0>\n", .{ expected_string, found_string });

                labels.appendAssumeCapacity(.{
                    .message = try printA(arena, "Return type is <r>{s}<0>", .{expected_string}),
                    .span = ast.nodeSpan(d.return_type_node),
                });

                labels.appendAssumeCapacity(.{
                    .message = try printA(arena, "Return value has type <r>{s}<0>", .{found_string}),
                    .span = s.span,
                });
            },
            .incompatible_if_branch_types => |d| {
                const then_string = d.then_type.toString();
                const else_string = d.else_type.toString();

                try print(writer, "`if` and `else` have incompatible types <r>{s}<0> and <r>{s}<0>\n", .{ then_string, else_string });

                labels.appendAssumeCapacity(.{
                    .message = try printA(arena, "Incompatible branches of this `if`", .{}),
                    .span = s.span,
                });

                labels.appendAssumeCapacity(.{
                    .message = try printA(arena, "`if` branch has type <r>{s}<0>", .{then_string}),
                    .span = ast.nodeSpan(d.then),
                });

                labels.appendAssumeCapacity(.{
                    .message = try printA(arena, "`else` branch has type <r>{s}<0>", .{else_string}),
                    .span = ast.nodeSpan(d.@"else"),
                });
            },
            .expected_type_because => |d| {
                const expected_string = d.expected.toString();
                const found_string = d.found.toString();

                try print(writer, "Expected type <r>{s}<0>, found <r>{s}<0>\n", .{ expected_string, found_string });

                labels.appendAssumeCapacity(.{
                    .message = try printA(arena, "Expected <r>{s}<0> due to this", .{expected_string}),
                    .span = ast.nodeSpan(d.because),
                });

                labels.appendAssumeCapacity(.{
                    .message = try printA(arena, "This has type <r>{s}<0>", .{found_string}),
                    .span = s.span,
                });
            },
            .expected_fn_type => |d| {
                const found_string = d.found.toString();

                try print(writer, "Expected a function, got value of type <r>{s}<0>\n", .{found_string});

                labels.appendAssumeCapacity(.{
                    .message = try printA(arena, "Value has type <r>{s}<0>", .{found_string}),
                    .span = s.span,
                });
            },
        }

        if (labels.items.len == 0) {
            labels.appendAssumeCapacity(.{
                .span = s.span,
                .message = "Error occurred here",
            });
        }

        std.mem.sort(Label, labels.items, {}, struct {
            pub fn inner(_: void, a: Label, b: Label) bool {
                return a.span.start < b.span.start;
            }
        }.inner);

        // find the largest line of the labels
        var largest_line: usize = 0;
        for (labels.items) |label| {
            const line_span = ast.getLine(label.span);
            const line_num = std.mem.countScalar(u8, ast.source[0..line_span.start], '\n') + 1;
            if (line_num > largest_line) largest_line = line_num;
        }

        const diag_line_span = ast.getLine(s.span);
        const diag_line_num = std.mem.countScalar(u8, ast.source[0..diag_line_span.start], '\n') + 1;
        const diag_column_num = s.span.start - diag_line_span.start + 1;
        const num_of_digits = std.math.log10_int(largest_line) + 1;

        try print(writer, "<d>", .{});
        for (0..num_of_digits + 2) |_| try writer.writeAll("─");

        try print(writer, "┬┄<0> <b>{s}:{d}:{d}<0>\n", .{
            "program",
            diag_line_num,
            diag_column_num,
        });

        // an example diagnostic
        //
        //[Error] Incompatible return types int and str
        //────┬┄ program.vac:27:8
        // 19 │ /// This function computes the `n`th Fibonacci number
        //    │ ──────────────────────────┬──────────────────────────
        //    │                           ╰┄ This doc comment is evil
        // 20 │ func fib(n int) int {
        //    │                 ─┬─
        //    ┆                  ╰┄ Return type is int
        // 27 │ return "42";
        //    │        ─┬──
        //    │         ╰┄ Return value has type str

        var i: usize = 0;
        while (i < labels.items.len) {
            const label = labels.items[i];

            // calculate label metadata
            const group_line_span = ast.getLine(label.span);

            var group_end = i + 1;
            while (group_end < labels.items.len) : (group_end += 1) {
                const line_span = ast.getLine(labels.items[group_end].span);
                if (group_line_span.start != line_span.start) break;
            }

            const is_last_group = group_end == labels.items.len;

            const group = labels.items[i..group_end];

            const group_line = std.mem.countScalar(u8, ast.source[0..group_line_span.start], '\n') + 1;
            const group_line_digits = std.math.log10_int(group_line);

            for (0..num_of_digits - group_line_digits) |_| try writer.writeByte(' ');
            try print(writer, "{d} <d>│<0> ", .{group_line});

            // print the alternating red and white of the line source
            var cursor = group_line_span.start;
            for (group) |g_label| {
                const start = @max(g_label.span.start, cursor);
                const end = @min(@max(g_label.span.end, start), group_line_span.end);
                try writer.writeAll(ast.source[cursor..start]);
                try print(writer, "<r>{s}<0>", .{ast.source[start..end]});
                cursor = end;
            }
            try print(writer, "{s}\n", .{ast.source[cursor..group_line_span.end]});

            // print all the pointers to the source
            try writer.splatByteAll(' ', num_of_digits + 2);
            try print(writer, "<d>│<0> <r>", .{});

            var col_cursor: usize = 0;
            for (group) |g_label| {
                const col = g_label.span.start - group_line_span.start;
                const span_len = g_label.span.end - g_label.span.start;
                try writer.splatByteAll(' ', col - col_cursor);

                col_cursor += col + span_len;

                const middle = (span_len) / 2;
                if (span_len <= 1) {
                    try writer.writeAll("▲");
                } else for (0..span_len) |j| {
                    if (j == middle) {
                        try writer.writeAll("┬");
                        continue;
                    }
                    try writer.writeAll("─");
                }
            }
            try print(writer, "<0>\n", .{});

            const is_next_line_consecutive = blk: {
                if (is_last_group) break :blk true;

                const next_label_span = labels.items[group_end].span;
                const next_line = group_line + std.mem.countScalar(
                    u8,
                    ast.source[group_line_span.end..next_label_span.start],
                    '\n',
                );

                break :blk (group_line + 1 == next_line);
            };

            // print the label tails
            var k = group.len;
            while (k > 0) {
                k -= 1;

                try writer.splatByteAll(' ', num_of_digits + 2);
                if (is_next_line_consecutive) {
                    try print(writer, "<d>│<0> ", .{});
                } else {
                    try print(writer, "<d>┆<0> ", .{});
                }

                // draw vertical drops for labels to the left (0..k), then `╰┄` for label k
                var drop_col: usize = 0;
                for (0..k) |left_idx| {
                    const left_lbl = group[left_idx];
                    const left_mid = (left_lbl.span.start - group_line_span.start) +
                        ((left_lbl.span.end - left_lbl.span.start) / 2);
                    if (left_mid >= drop_col) {
                        try writer.splatByteAll(' ', left_mid - drop_col);
                        try print(writer, "<r>│<0>", .{});
                        drop_col = left_mid + 1;
                    }
                }

                const curr_lbl = group[k];
                const curr_mid = (curr_lbl.span.start - group_line_span.start) +
                    ((curr_lbl.span.end - curr_lbl.span.start) / 2);
                if (curr_mid >= drop_col) {
                    try writer.splatByteAll(' ', curr_mid - drop_col);
                }
                try print(writer, "<r>╰┄<0> {s}\n", .{curr_lbl.message});
            }

            i = group_end;
        }
    }
};

pub fn add(s: *Diagnostics, diag: Diagnostic) std.mem.Allocator.Error!void {
    try s.diagnostics.append(s.gpa, diag);
}

pub fn reportAll(s: *Diagnostics, ast: *const Ast, writer: *std.Io.Writer) error{ WriteFailed, OutOfMemory }!void {
    try writer.writeByte('\n');
    for (0..s.diagnostics.len) |i| {
        const diag = s.diagnostics.get(i);
        try diag.write(s.arena.allocator(), ast, writer);
        try writer.writeByte('\n');
    }
}
