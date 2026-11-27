const std = @import("std");

pub const parsers = struct {
    pub fn string(in: []const u8) error{}![]const u8 {
        return in;
    }
};

pub fn ComptimeStack(comptime T: type, comptime max_size: usize) type {
    return struct {
        const Self = @This();

        items: [max_size]T,
        len: usize,

        const empty: Self = .{
            .items = undefined,
            .len = 0,
        };

        pub fn push(comptime s: *Self, comptime item: T) void {
            if (s.len == max_size) @compileError("Stack size exceeded max bound");
            s.items[s.len] = item;
            s.len += 1;
        }

        pub fn pop(comptime s: *Self) T {
            s.len -= 1;
            return s.items[s.len];
        }

        pub fn last(comptime s: *Self) T {
            return s.items[s.len - 1];
        }
    };
}

pub const Diagnostics = struct {
    offender: []const u8,
};

pub const ParamRange = struct {
    start: u32,
    end: u32,
};
pub const Subcommand = struct {
    name: []const u8,
    help: []const u8,
    branches: ParamRange,
    options: ParamRange,
    positionals: ParamRange,
};
pub const Positional = struct {
    type: []const u8,
};
pub const Option = struct {
    help: []const u8,
    short: ?u8,
    // all options should always have a --... form
    long: []const u8,
    positional: ?u32,
};

pub const ArgsError = error{
    LoneSingleDash,
    SingleDashLong,
    UnexpectedArg,
    UnknownOption,
    NotEnoughArgs,
};

pub fn dupeStringComptime(comptime slice: []const u8) []const u8 {
    const copy: [slice.len]u8 = slice[0..slice.len].*;
    return &copy;
}

pub fn ParamsTree(
    comptime subcmds_count: usize,
    comptime positionals_count: usize,
    comptime options_count: usize,
) type {
    return struct {
        root: Subcommand,
        subcommands: [subcmds_count]Subcommand,
        positionals: [positionals_count]Positional,
        options: [options_count]Option,

        pub fn ParseResult(comptime tree: *const @This(), comptime value_parsers: anytype) type {
            if (!@inComptime()) @compileError("`ParseResult` must be called at comptime");

            return tree.SubcommandResult(tree.root, value_parsers);
        }

        fn SubcommandResult(comptime tree: *const @This(), comptime cmd: Subcommand, comptime value_parsers: anytype) type {
            const Positionals = blk: {
                if (cmd.positionals.end - cmd.positionals.start == 0) break :blk void;

                var positionals: [cmd.positionals.end - cmd.positionals.start]type = undefined;
                for (tree.positionals[cmd.positionals.start..cmd.positionals.end], 0..) |positional, i| {
                    const parser = @field(value_parsers, positional.type);
                    const ReturnType = @typeInfo(@TypeOf(parser)).@"fn".return_type.?;
                    const PosType = @typeInfo(ReturnType).error_union.payload;

                    positionals[i] = PosType;
                }

                break :blk @Tuple(&positionals);
            };

            const Options = blk: {
                const num_of_options = cmd.options.end - cmd.options.start;

                if (num_of_options == 0) break :blk void;

                var option_types: [num_of_options]type = undefined;
                var option_names: [num_of_options][]const u8 = undefined;
                var option_attrs: [num_of_options]std.lang.Type.Struct.FieldAttributes = undefined;

                for (tree.options[cmd.options.start..cmd.options.end], 0..) |option, i| {
                    if (option.positional) |pos_idx| {
                        const positional = tree.positionals[pos_idx];
                        const parser = @field(value_parsers, positional.type);
                        const ReturnType = @typeInfo(@TypeOf(parser)).@"fn".return_type.?;
                        const OptionType = ?@typeInfo(ReturnType).error_union.payload;

                        option_types[i] = OptionType;
                        option_attrs[i] = .{ .default_value_ptr = &@as(OptionType, null) };
                    } else {
                        option_types[i] = bool;
                        option_attrs[i] = .{ .default_value_ptr = &false };
                    }

                    option_names[i] = option.long;
                }

                break :blk @Struct(.auto, null, &option_names, &option_types, &option_attrs);
            };

            const Subcommands = blk: {
                const num_of_subcommands = cmd.branches.end - cmd.branches.start;

                if (num_of_subcommands == 0) {
                    return struct {
                        opts: Options = .{},
                        pos_args: Positionals = undefined,
                    };
                }

                var subcommand_names: [num_of_subcommands + 2][]const u8 = undefined;
                var subcommand_types: [num_of_subcommands + 2]type = undefined;
                var one_to_n: [num_of_subcommands + 2]u16 = undefined;

                for (tree.subcommands[cmd.branches.start..cmd.branches.end], 0..) |subcommand, i| {
                    subcommand_names[i] = subcommand.name;
                    subcommand_types[i] = tree.SubcommandResult(subcommand, value_parsers);
                    one_to_n[i] = i;
                }

                subcommand_names[num_of_subcommands + 1] = "pos_args";
                subcommand_types[num_of_subcommands + 1] = Positionals;
                one_to_n[num_of_subcommands + 1] = num_of_subcommands + 1;

                subcommand_names[num_of_subcommands] = "none";
                subcommand_types[num_of_subcommands] = void;
                one_to_n[num_of_subcommands] = num_of_subcommands;

                break :blk @Union(
                    .auto,
                    @Enum(u16, .exhaustive, &subcommand_names, &one_to_n),
                    &subcommand_names,
                    &subcommand_types,
                    &@splat(.{}),
                );
            };

            return struct {
                opts: Options = .{},
                cmd: Subcommands = .none,
            };
        }

        pub fn parse(
            comptime tree: *const @This(),
            comptime value_parsers: anytype,
            args: std.process.Args,
            arena: std.mem.Allocator,
            diag: *Diagnostics,
        ) !tree.ParseResult(value_parsers) {
            const arg_slice = try args.toSlice(arena);
            if (arg_slice.len == 1) return error.NotEnoughArgs;

            return tree.parseSubcmd(value_parsers, tree.root, arg_slice[1..], 0, diag);
        }

        pub fn parseSubcmd(
            comptime tree: *const @This(),
            comptime value_parsers: anytype,
            comptime cmd: Subcommand,
            args: []const []const u8,
            start: usize,
            diag: *Diagnostics,
        ) !tree.SubcommandResult(cmd, value_parsers) {
            var res: tree.SubcommandResult(cmd, value_parsers) = .{};

            var current_positional: usize = 0;
            var i = start;

            defer if (i < args.len) {
                diag.offender = args[i];
            } else {
                diag.offender = "";
            };

            args_loop: while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (arg[0] == '-') {
                    if (arg.len == 1) return error.LoneSingleDash;

                    if (arg[1] != '-') {
                        if (arg.len != 2) return error.SingleDashLong;
                        const short = arg[1];

                        inline for (tree.options[cmd.options.start..cmd.options.end]) |option| {
                            if (option.short == null) continue;
                            if (option.short.? == short) {
                                @field(res.opts, option.long) = if (option.positional) |pos_idx| blk: {
                                    const positional = tree.positionals[pos_idx];
                                    i += 1;
                                    if (i >= args.len) return error.NotEnoughArgs;

                                    break :blk try @field(value_parsers, positional.type)(args[i]);
                                } else true;
                                continue :args_loop;
                            }
                        }

                        return error.UnknownOption;
                    }

                    inline for (tree.options[cmd.options.start..cmd.options.end]) |option| {
                        if (std.mem.eql(u8, arg[2..], option.long)) {
                            @field(res.opts, option.long) = if (option.positional) |pos_idx| blk: {
                                const positional = tree.positionals[pos_idx];
                                i += 1;
                                if (i >= args.len) return error.NotEnoughArgs;

                                break :blk try @field(value_parsers, positional.type)(args[i]);
                            } else true;
                            continue :args_loop;
                        }
                    }

                    return error.UnknownOption;
                }

                inline for (tree.subcommands[cmd.branches.start..cmd.branches.end]) |subcmd| {
                    if (std.mem.eql(u8, arg, subcmd.name)) {
                        i += 1;
                        res.cmd = @unionInit(
                            @TypeOf(res.cmd),
                            subcmd.name,
                            try tree.parseSubcmd(value_parsers, subcmd, args, i, diag),
                        );
                        return res;
                    }
                }

                switch (current_positional) {
                    inline 0...cmd.positionals.end - cmd.positionals.start - 1 => |current_pos| {
                        const positional = tree.positionals[current_pos];
                        if (i >= args.len) return error.NotEnoughArgs;
                        const pos_arg = args[i];

                        const result = try @field(value_parsers, positional.type)(pos_arg);

                        if (cmd.branches.end - cmd.branches.start == 0) {
                            @field(res.pos_args, std.fmt.comptimePrint("{d}", .{current_pos})) = result;
                        } else {
                            res.cmd = @unionInit(@TypeOf(res.cmd), "pos_args", undefined);
                            @field(res.cmd.pos_args, std.fmt.comptimePrint("{d}", .{current_pos})) = result;
                        }
                        current_positional += 1;
                    },
                    else => return error.UnexpectedArg,
                }
            }

            return res;
        }

        fn optionHelpString(comptime tree: *const @This(), option: Option) []const u8 {
            var result: []const u8 = "  ";
            if (option.short) |short| {
                result = result ++ "\x1b[33m-" ++ .{short} ++ "\x1b[0m, ";
            } else {
                result = result ++ "    ";
            }
            result = result ++ "\x1b[33m--" ++ option.long ++ "\x1b[0m";
            if (option.positional) |positional| {
                result = result ++ " \x1b[32m<" ++ tree.positionals[positional].type ++ ">\x1b[0m";
            }

            result = result ++ "    " ++ option.help ++ "\n";
        }

        fn optionStringLength(comptime tree: *const @This(), option: Option) usize {
            var len: usize = option.long.len;
            if (option.positional) |positional| {
                len += 3 + tree.positionals[positional].type.len;
            }

            return len;
        }

        pub fn helpString(comptime tree: *const @This(), comptime bin_name: []const u8) []const u8 {
            if (!@inComptime()) @compileError("`helpString` must be called at comptime");

            const root = tree.root;

            const max_option_length = blk: {
                var result: usize = 0;
                for (tree.options[root.options.start..root.options.end]) |option| {
                    result = @max(result, tree.optionStringLength(option));
                }
                break :blk result;
            };

            var help: []const u8 = "\x1b[1mUsage:\x1b[0m \x1b[36m" ++ bin_name ++ "\x1b[0m";

            for (tree.positionals[root.positionals.start..root.positionals.end]) |positional| {
                help = help ++ " \x1b[32m<" ++ positional.type ++ ">\x1b[0m";
            }

            help = help ++ "\n" ++ root.help ++ "\n\n\x1b[1mOptions:\x1b[0m\n\n";

            for (tree.options[root.options.start..root.options.end]) |option| {
                help = help ++ "  ";
                if (option.short) |short| {
                    help = help ++ "\x1b[33m-" ++ .{short} ++ "\x1b[0m, ";
                } else {
                    help = help ++ "    ";
                }
                help = help ++ "\x1b[33m--" ++ option.long ++ "\x1b[0m";
                if (option.positional) |positional| {
                    help = help ++ " \x1b[32m<" ++ tree.positionals[positional].type ++ ">\x1b[0m";
                }

                const length = tree.optionStringLength(option);
                const spaces: *const [max_option_length - length + 4]u8 = &@splat(' ');

                help = help ++ spaces ++ option.help ++ "\n";
            }

            help = help ++ "\n\x1b[1mSubcommands:\x1b[0m\n\n";

            for (tree.subcommands[root.branches.start..root.branches.end]) |subcommand| {
                help = help ++ "  \x1b[36m" ++ subcommand.name ++ "\x1b[0m";
                for (tree.positionals[subcommand.positionals.start..subcommand.positionals.end]) |positional| {
                    help = help ++ " \x1b[32m<" ++ positional.type ++ ">\x1b[0m";
                }

                help = help ++ "    " ++ subcommand.help ++ "\n";
            }

            return help;
        }
    };
}

pub fn countSubcommands(comptime str: []const u8) usize {
    @setEvalBranchQuota(4096);
    var subcommands: usize = 0;

    var it = std.mem.splitScalar(u8, str, '\n');
    lines: while (it.next()) |line| {
        var i = 0;
        while (i < line.len) {
            switch (line[i]) {
                ' ' => {
                    i += 1;
                },
                'a'...'z' => {
                    subcommands += 1;
                    continue :lines;
                },
                else => {
                    continue :lines;
                },
            }
        }
    }

    return subcommands;
}

pub fn countPositionals(comptime str: []const u8) usize {
    @setEvalBranchQuota(4096);
    var positionals = 0;

    var i = 0;
    while (i < str.len) {
        switch (str[i]) {
            ':' => {
                while (i < str.len and str[i] != '\n') i += 1;
            },
            '<' => positionals += 1,
            else => {},
        }

        i += 1;
    }

    return positionals;
}

pub fn countOptions(comptime str: []const u8) usize {
    @setEvalBranchQuota(4096);
    var options: usize = 0;

    var it = std.mem.splitScalar(u8, str, '\n');
    lines: while (it.next()) |line| {
        var i = 0;
        while (i < line.len) {
            switch (line[i]) {
                ' ' => {
                    i += 1;
                },
                '-' => {
                    options += 1;
                    continue :lines;
                },
                else => {
                    continue :lines;
                },
            }
        }
    }

    return options;
}

pub fn ParseParamsReturn(comptime str: []const u8) type {
    return ParamsTree(
        countSubcommands(str),
        countPositionals(str),
        countOptions(str),
    );
}

pub fn parseParams(comptime str: []const u8) ParseParamsReturn(str) {
    if (!@inComptime()) @compileError("`parseParams` must be called at comptime");

    var tree: ParseParamsReturn(str) = .{
        .root = undefined,
        .subcommands = undefined,
        .positionals = undefined,
        .options = undefined,
    };
    var subcommands_len: usize = 0;
    var positionals_len: usize = 0;
    var options_len: usize = 0;

    var subcommands_stack: ComptimeStack(struct { i32, Subcommand }, 16) = .empty;
    // the root node
    subcommands_stack.push(.{ -1, .{
        .name = "",
        .help = "",
        .positionals = .{ .start = 0, .end = 0 },
        .options = .{ .start = 0, .end = 0 },
        .branches = .{ .start = 0, .end = 0 },
    } });

    var i: usize = 0;
    var indent: usize = 0;

    while (i < str.len) switch (str[i]) {
        '-' => {
            var option: Option = .{
                .help = "",
                .long = "",
                .short = null,
                .positional = null,
            };

            outer: while (i < str.len) switch (str[i]) {
                ' ' => i += 1,
                '\n' => break :outer,
                '-' => {
                    i += 1;
                    if (str[i] == '-') {
                        i += 1;
                        const start = i;
                        while (i < str.len and (str[i] != ' ' and str[i] != '\n')) i += 1;
                        option.long = dupeStringComptime(str[start..i]);

                        continue :outer;
                    }

                    option.short = str[i];

                    i += 1;
                },
                '<' => {
                    i += 1;
                    const start = i;

                    while (i < str.len and str[i] != '>') i += 1;
                    if (i >= str.len) @compileError("need closing '>'");

                    option.positional = positionals_len;

                    tree.positionals[positionals_len] = .{ .type = dupeStringComptime(str[start..i]) };
                    positionals_len += 1;

                    i += 1;
                },
                ':' => {
                    i += 1;
                    while (i < str.len and str[i] == ' ') i += 1;
                    const start = i;
                    while (i < str.len and str[i] != '\n') i += 1;

                    option.help = dupeStringComptime(str[start..i]);
                },
                else => @compileError(std.fmt.comptimePrint("cannot parse character '{c}'", .{str[i]})),
            };

            tree.options[options_len] = option;
            options_len += 1;

            subcommands_stack.items[subcommands_stack.len - 1].@"1".options.end = options_len;
        },
        '<' => {
            i += 1;
            const start = i;

            while (i < str.len and str[i] != '>') i += 1;
            if (i >= str.len) @compileError("need closing '>'");

            tree.positionals[positionals_len] = .{ .type = dupeStringComptime(str[start..i]) };
            positionals_len += 1;
            subcommands_stack.items[subcommands_stack.len - 1].@"1".positionals.end = positionals_len;

            i += 1;
        },
        '\n' => {
            const before_indent = indent;
            i += 1;

            const start = i;

            while (i < str.len and str[i] == ' ') i += 1;
            indent = i - start;

            if (before_indent > indent or subcommands_stack.last().@"0" == indent) {
                const subcommand = subcommands_stack.pop();
                if (subcommands_stack.len < 1) @compileError("wrong indentation");

                tree.subcommands[subcommands_len] = subcommand.@"1";
                subcommands_len += 1;
                subcommands_stack.items[subcommands_stack.len - 1].@"1".branches.end = subcommands_len;
            }
        },
        ' ' => i += 1,
        'a'...'z' => {
            const start = i;
            i += 1;
            while (i < str.len and std.ascii.isLower(str[i])) i += 1;
            subcommands_stack.push(.{ indent, .{
                .help = "",
                .name = dupeStringComptime(str[start..i]),
                .branches = .{ .start = subcommands_len, .end = subcommands_len },
                .positionals = .{ .start = positionals_len, .end = positionals_len },
                .options = .{ .start = options_len, .end = options_len },
            } });

            while (i < str.len and str[i] == ' ') i += 1;
        },
        ':' => {
            i += 1;
            while (i < str.len and str[i] == ' ') i += 1;
            const start = i;
            while (i < str.len and str[i] != '\n') i += 1;

            subcommands_stack.items[subcommands_stack.len - 1].@"1".help = dupeStringComptime(str[start..i]);
        },
        else => @compileError(std.fmt.comptimePrint("cannot parse character '{c}'", str[i])),
    };

    // the root node should still be in there
    std.debug.assert(subcommands_stack.len == 1);

    tree.root = subcommands_stack.pop().@"1";

    return tree;
}
