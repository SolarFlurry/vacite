const std = @import("std");

const Symbol = @import("Symbol.zig");

pub const Scope = union(enum) {
    var_decl: struct {
        /// if it was initialised with `var`
        is_var: bool,
        /// the identifier string
        ident: []const u8,
        symbol: Symbol,
    },
};
