const std = @import("std");

const Ast = @import("Ast.zig");
pub const Builder = @import("Diagnostics/Builder.zig");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const Span = Lexer.Span;
const print = @import("pretty_print.zig").print;

const Diagnostics = @This();

gpa: std.mem.Allocator,
diagnostics: std.MultiArrayList(Diagnostic),

pub fn init(gpa: std.mem.Allocator) Diagnostics {
    return .{
        .gpa = gpa,
        .diagnostics = .empty,
    };
}

pub fn deinit(s: *Diagnostics) void {
    s.diagnostics.deinit(s.gpa);
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
        expected_closing: Token.Tag,
        no_main_func: void,
    };

    pub fn write(s: *const Diagnostic, ast: *const Ast, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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
            .expected_closing => |d| try print(writer, "Expected matching closing {s}\n", .{d.describe()}),
            .no_main_func => try print(writer, "No 'main' function\n", .{}),
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

        for (0..num_of_digits + 2) |_| try writer.writeAll("─");

        try print(writer, "┬┄ {s}:{d}:{d}\n", .{
            "program",
            diag_line_num,
            diag_column_num,
        });

        for (labels.items, 0..) |label, i| {
            const label_line_span = ast.getLine(s.span);
            const label_line_num = std.mem.countScalar(u8, ast.source[0..label_line_span.start], '\n') + 1;
            const label_col = label.span.start - label_line_span.start;
            const label_line_digits = std.math.log10_int(label_line_num);
            const label_span_len = label.span.end - label.span.start;

            for (0..num_of_digits - label_line_digits) |_| try writer.writeByte(' ');
            try print(writer, "{d} │ {s}<r>{s}<0>{s}\n", .{
                label_line_num,
                ast.source[label_line_span.start..label.span.start],
                ast.source[label.span.start..label.span.end],
                ast.source[label.span.end..label_line_span.end],
            });

            try writer.splatByteAll(' ', num_of_digits + 2);
            try writer.writeAll("│");

            try writer.splatByteAll(' ', label_col + 1);

            try print(writer, "<r>", .{});
            const middle = (label_span_len) / 2;
            if (label_span_len <= 1) {
                try writer.writeAll("▲");
            } else for (0..label.span.end - label.span.start) |j| {
                if (j == middle) {
                    try writer.writeAll("┬");
                    continue;
                }
                try writer.writeAll("─");
            }
            try print(writer, "<0>\n", .{});

            if (i < labels.items.len - 1) {
                try writer.splatByteAll(' ', num_of_digits + 2);
                try writer.writeAll("│ ");
            } else {
                try writer.splatBytesAll("─", num_of_digits + 2);
                try writer.writeAll("┴┄");
            }

            try writer.splatByteAll(' ', label_col + middle);
            try print(writer, "<r>╰┄ {s}<0>\n", .{label.message});
        }
    }
};

pub fn add(s: *Diagnostics, diag: Diagnostic) std.mem.Allocator.Error!void {
    try s.diagnostics.append(s.gpa, diag);
}

pub fn reportAll(s: *const Diagnostics, ast: *const Ast, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (0..s.diagnostics.len) |i| {
        const diag = s.diagnostics.get(i);
        try diag.write(ast, writer);
    }
}
