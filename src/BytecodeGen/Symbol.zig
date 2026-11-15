const std = @import("std");

const Symbol = @This();

value: Value,
type: Type,

pub fn atomicType(kind: Type.Kind) Symbol {
    return .{
        .value = .{ .type = .atomic(kind) },
        .type = .atomic(.type),
    };
}

pub const Value = union(enum) {
    /// index into constants array
    constant: usize,
    /// allocated register
    reg: u8,
    /// holds a compile time type value
    type: Type,
};

pub const Type = struct {
    kind: Kind,
    // data: Data,

    pub const Kind = enum(u8) {
        int,
        real,
        bool,
        str,
        type,
        void,
        noreturn,
        poison,
        _,
    };

    pub const Data = union {};

    pub fn atomic(kind: Kind) Type {
        return .{ .kind = kind };
    }

    pub fn toString(t: Type) []const u8 {
        switch (t.kind) {
            .int => return "int",
            .real => return "real",
            .bool => return "bool",
            .str => return "str",
            .type => return "type",
            .void => return "void",
            .noreturn => return "noreturn",
            else => return "(unknown)",
        }
    }

    pub fn eql(a: Type, b: Type) bool {
        return a.kind == b.kind;
    }

    pub fn compatible(a: Type, b: Type) bool {
        if (a.kind == .poison or b.kind == .poison) return true;
        if (a.kind == .noreturn or b.kind == .noreturn) return true;
        return eql(a, b);
    }
};
