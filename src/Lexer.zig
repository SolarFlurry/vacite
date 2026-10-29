const std = @import("std");

const Self = @This();

source: [:0]const u8,
index: usize,

pub const Token = struct {
    tag: Tag,
    loc: struct { start: usize, end: usize },

    pub const Tag = enum {
        invalid,
        eof,
        identifier,
        int_literal,
        float_literal,
        string_literal,
        keyword_let,
        keyword_var,
        keyword_func,
        keyword_return,
        keyword_continue,
        keyword_break,
        keyword_if,
        keyword_then,
        keyword_else,
        keyword_while,
        l_brace,
        r_brace,
        l_paren,
        r_paren,
        l_brack,
        r_brack,
        semicolon,
        equal,
        equal_equal,
        plus,
        plus_equal,
        minus,
        minus_equal,
        asterisk,
        asterisk_equal,
        slash,
        slash_equal,
        comma,

        pub fn lexeme(tag: Tag) []const u8 {
            return switch (tag) {
                .minus => "-",
                .plus => "+",
                .asterisk => "*",
                .slash => "/",
                else => unreachable,
            };
        }
    };

    const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "let", .keyword_let },
        .{ "var", .keyword_var },
        .{ "func", .keyword_func },
        .{ "return", .keyword_return },
        .{ "continue", .keyword_continue },
        .{ "break", .keyword_break },
        .{ "if", .keyword_if },
        .{ "then", .keyword_then },
        .{ "else", .keyword_else },
        .{ "while", .keyword_while },
    });
};

const State = enum {
    start,
    invalid,
    comment,
    identifier,
    integer,
    float,
    equal,
    plus,
    minus,
    asterisk,
    slash,
};

pub fn init(source: [:0]const u8) Self {
    return .{
        .source = source,
        .index = 0,
    };
}

pub fn next(self: *Self) Token {
    var result: Token = .{
        .tag = undefined,
        .loc = .{
            .start = self.index,
            .end = undefined,
        },
    };
    state: switch (State.start) {
        .start => switch (self.source[self.index]) {
            0 => {
                if (self.index == self.source.len) return .{
                    .tag = .eof,
                    .loc = .{
                        .start = self.index,
                        .end = self.index,
                    },
                } else continue :state .invalid;
            },
            ' ', '\t', '\n', '\r' => {
                self.index += 1;
                result.loc.start = self.index;
                continue :state .start;
            },
            '#' => continue :state .comment,
            'a'...'z', 'A'...'Z', '_' => {
                result.tag = .identifier;
                continue :state .identifier;
            },
            '0'...'9' => {
                result.tag = .int_literal;
                continue :state .integer;
            },
            '=' => continue :state .equal,
            '+' => continue :state .plus,
            '-' => continue :state .minus,
            '*' => continue :state .asterisk,
            '/' => continue :state .slash,
            '(' => {
                self.index += 1;
                result.tag = .l_paren;
            },
            ')' => {
                self.index += 1;
                result.tag = .r_paren;
            },
            '[' => {
                self.index += 1;
                result.tag = .l_brack;
            },
            ']' => {
                self.index += 1;
                result.tag = .r_brack;
            },
            '{' => {
                self.index += 1;
                result.tag = .l_brace;
            },
            '}' => {
                self.index += 1;
                result.tag = .r_brace;
            },
            ';' => {
                self.index += 1;
                result.tag = .semicolon;
            },
            ',' => {
                self.index += 1;
                result.tag = .comma;
            },
            else => continue :state .invalid,
        },
        .invalid => {
            self.index += 1;
            switch (self.source[self.index]) {
                0 => if (self.index == self.source.len) {
                    result.tag = .invalid;
                } else {
                    continue :state .invalid;
                },
                '\n' => result.tag = .invalid,
                else => continue :state .invalid,
            }
        },
        .comment => {
            self.index += 1;
            switch (self.source[self.index]) {
                0, '\n' => continue :state .start,
                else => continue :state .comment,
            }
        },
        .identifier => {
            self.index += 1;
            switch (self.source[self.index]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9', '\'' => continue :state .identifier,
                else => {
                    const ident = self.source[result.loc.start..self.index];
                    if (Token.keywords.get(ident)) |tag| {
                        result.tag = tag;
                    }
                },
            }
        },
        .integer => {
            self.index += 1;
            switch (self.source[self.index]) {
                '0'...'9', '_' => continue :state .integer,
                '.' => {
                    self.index += 1;
                    result.tag = .float_literal;
                },
                else => {},
            }
        },
        .float => {
            self.index += 1;
            switch (self.source[self.index]) {
                '0'...'9', '_' => continue :state .float,
                else => {},
            }
        },
        .equal => {
            self.index += 1;
            switch (self.source[self.index]) {
                '=' => {
                    self.index += 1;
                    result.tag = .equal_equal;
                },
                else => result.tag = .equal,
            }
        },
        .plus => {
            self.index += 1;
            switch (self.source[self.index]) {
                '=' => {
                    self.index += 1;
                    result.tag = .plus_equal;
                },
                else => result.tag = .plus,
            }
        },
        .minus => {
            self.index += 1;
            switch (self.source[self.index]) {
                '=' => {
                    self.index += 1;
                    result.tag = .minus_equal;
                },
                else => result.tag = .minus,
            }
        },
        .asterisk => {
            self.index += 1;
            switch (self.source[self.index]) {
                '=' => {
                    self.index += 1;
                    result.tag = .asterisk_equal;
                },
                else => result.tag = .asterisk,
            }
        },
        .slash => {
            self.index += 1;
            switch (self.source[self.index]) {
                '=' => {
                    self.index += 1;
                    result.tag = .slash_equal;
                },
                else => result.tag = .slash,
            }
        },
    }

    result.loc.end = self.index;
    return result;
}
