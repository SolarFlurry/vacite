const std = @import("std");

value: Value,
type: Type,

pub const Value = union(enum) {
    /// index into constants array
    constant: usize,
    /// allocated register
    reg: u8,
};

pub const Type = struct {
    kind: Kind,

    pub const Kind = enum {
        int,
        real,
        bool,
        str,
    };

    pub fn eql(a: Type, b: Type) bool {
        return a.kind == b.kind;
    }
};
