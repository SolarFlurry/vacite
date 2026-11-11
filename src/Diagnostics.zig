const std = @import("std");

const Ast = @import("Ast.zig");
pub const Builder = @import("Diagnostics/Builder.zig");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const Span = Lexer.Span;

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

    pub const Level = enum(u8) {
        @"error",
        warning,
        hint,
    };

    pub const Data = union(enum(u8)) {
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
        switch (s.level) {
            .@"error" => try print(writer, "<rB>[Error]<0> ", .{}),
            .warning => try print(writer, "<yB>[Warning]<0> ", .{}),
            else => try writer.writeAll("[Diagnostic] "),
        }

        switch (s.data) {
            .unexpected_token => |d| try print(writer, "Unexpected <y>'{s}'<0>\n", .{tokenString(ast, d)}),
            .expected_token => |d| try print(writer, "Expected {s}, got {s}\n", .{ d.expected.describe(), d.unexpected.describe() }),
            .expected_expr => |d| try print(writer, "Expected an expression, got {s}\n", .{d.describe()}),
            .expected_decl => |d| try print(writer, "Expected a declaration, got {s}\n", .{d.describe()}),
            .expected_closing => |d| try print(writer, "Expected matching closing {s}\n", .{d.describe()}),
            .no_main_func => try print(writer, "No 'main' function\n", .{}),
        }

        const line_span = ast.getLine(s.span);
        const line_num = ast.countLines(.{ .start = 0, .end = line_span.start }) + 1;
        const column_num = line_span.start - line_span.start + 1;
        const num_of_digits = std.math.log10_int(line_num) + 1;

        for (0..num_of_digits + 2) |_| try writer.writeByte(' ');
        try print(writer,
            \\╭┄ {s}:{d}:{d}
            \\ {1d} │ {s}<r>{s}<0>{s}
            \\
        , .{
            "program",
            line_num,
            column_num,
            ast.source[line_span.start..s.span.start],
            ast.source[s.span.start..s.span.end],
            ast.source[s.span.end..line_span.end],
        });
        for (0..num_of_digits + 2) |_| try writer.writeAll("─");
        try writer.writeAll("╯\n");
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

/// Zig's standard `print` but with ANSI formats!!
/// Most of this code is copied from the `std.Io.Writer.print` function
/// graphics:
///  <0> reset
///  <B> bold
///  <d> dim
///  <i> italics
///  <u> underline
/// colors:
///  <k> black
///  <r> red
///  <g> green
///  <y> yellow
///  <b> blue
///  <m> magenta
///  <c> cyan
///  <w> white
///
///  You can chain them together like so:
///   <Br> bold red
///   <id> italic dim
fn print(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
    const assert = std.debug.assert;

    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
    }

    const field_names = args_type_info.@"struct".field_names;
    const max_format_args = @typeInfo(std.fmt.ArgSetType).int.bits;
    if (field_names.len > max_format_args) {
        @compileError("32 arguments max are supported per format call");
    }

    @setEvalBranchQuota(@as(comptime_int, fmt.len) * 1000); // NOTE: We're upcasting as 16-bit usize overflows.
    comptime var arg_state: std.fmt.ArgState = .{ .args_len = field_names.len };
    comptime var i = 0;
    comptime var literal: []const u8 = "";
    inline while (true) {
        const start_index = i;

        inline while (i < fmt.len) {
            switch (fmt[i]) {
                '{', '}', '<', '>' => break,
                else => i += 1,
            }
        }

        comptime var end_index = i;
        comptime var unescape_brace = false;

        // Handle {{, }}, << and >>, those are un-escaped as single braces
        if (i + 1 < fmt.len and fmt[i + 1] == fmt[i]) {
            unescape_brace = true;
            // Make the first brace part of the literal...
            end_index += 1;
            // ...and skip both
            i += 2;
        }

        literal = literal ++ fmt[start_index..end_index];

        // We've already skipped the other brace, restart the loop
        if (unescape_brace) continue;

        // Write out the literal
        if (literal.len != 0 and (i >= fmt.len or fmt[i] != '<')) {
            try w.writeAll(literal);
            literal = "";
        }

        if (i >= fmt.len) break;

        const brace_kind = fmt[i];
        const opposite_brace_kind = switch (brace_kind) {
            '{' => '}',
            '<' => '>',
            else => '?',
        };

        if (fmt[i] == '}') {
            @compileError("missing opening {");
        }
        if (fmt[i] == '>') {
            @compileError("missing opening <");
        }

        // Get past the { or <
        comptime assert(fmt[i] == '{' or fmt[i] == '<');
        i += 1;

        const fmt_begin = i;
        // Find the closing brace
        inline while (i < fmt.len and fmt[i] != opposite_brace_kind) i += 1;

        const fmt_end = i;

        if (i >= fmt.len) {
            @compileError(std.fmt.comptimePrint("missing closing {c}", .{opposite_brace_kind}));
        }

        // Get past the } or >
        comptime assert(fmt[i] == opposite_brace_kind);
        i += 1;

        if (brace_kind == '<') {
            literal = literal ++ "\x1b[";
            inline for (fmt[fmt_begin..fmt_end], 1..) |c, j| {
                literal = literal ++ switch (c) {
                    '0' => "0",
                    'B' => "1",
                    'd' => "2",
                    'i' => "3",
                    'u' => '4',
                    'k' => "30",
                    'r' => "31",
                    'g' => "32",
                    'y' => "33",
                    'b' => "34",
                    'm' => "35",
                    'c' => "36",
                    'w' => "37",
                    else => @compileError(std.fmt.comptimePrint("unknown ANSI format '{c}'", .{c})),
                } ++ if (j == fmt_end - fmt_begin) "" else ";";
            }
            literal = literal ++ "m";
            continue;
        }

        const placeholder_array = fmt[fmt_begin..fmt_end].*;
        const placeholder = comptime std.fmt.Placeholder.parse(&placeholder_array);
        const arg_pos = comptime switch (placeholder.arg) {
            .none => null,
            .number => |pos| pos,
            .named => |arg_name| std.meta.fieldIndex(ArgsType, arg_name) orelse
                @compileError("no argument with name '" ++ arg_name ++ "'"),
        };

        const width = switch (placeholder.width) {
            .none => null,
            .number => |v| v,
            .named => |arg_name| blk: {
                const arg_i = comptime std.meta.fieldIndex(ArgsType, arg_name) orelse
                    @compileError("no argument with name '" ++ arg_name ++ "'");
                _ = comptime arg_state.nextArg(arg_i) orelse @compileError("too few arguments");
                break :blk @field(args, arg_name);
            },
        };

        const precision = switch (placeholder.precision) {
            .none => null,
            .number => |v| v,
            .named => |arg_name| blk: {
                const arg_i = comptime std.meta.fieldIndex(ArgsType, arg_name) orelse
                    @compileError("no argument with name '" ++ arg_name ++ "'");
                _ = comptime arg_state.nextArg(arg_i) orelse @compileError("too few arguments");
                break :blk @field(args, arg_name);
            },
        };

        const arg_to_print = comptime arg_state.nextArg(arg_pos) orelse
            @compileError("too few arguments");

        try w.printValue(
            placeholder.specifier_arg,
            .{
                .fill = placeholder.fill,
                .alignment = placeholder.alignment,
                .width = width,
                .precision = precision,
            },
            @field(args, field_names[arg_to_print]),
            std.options.fmt_max_depth,
        );
    }

    if (comptime arg_state.hasUnusedArgs()) {
        const missing_count = arg_state.args_len - @popCount(arg_state.used_args);
        switch (missing_count) {
            0 => unreachable,
            1 => @compileError("unused argument in '" ++ fmt ++ "'"),
            else => @compileError(std.fmt.comptimePrint("{d}", .{missing_count}) ++ " unused arguments in '" ++ fmt ++ "'"),
        }
    }
}
