const std = @import("std");

const Symbol = @This();

value: Value,
type: Type.Ref,

pub fn atomicType(ref: Type.Ref) Symbol {
    return .{
        .value = .{ .type = ref },
        .type = .type,
    };
}

pub const Value = union(enum) {
    /// index into constants array
    constant: usize,
    /// allocated register
    reg: u8,
    /// holds a compile time type value
    type: Type.Ref,
};

pub const Type = union(enum(u8)) {
    func: struct {
        return_type: Ref,
    },

    pub const Ref = enum(u32) {
        int,
        real,
        bool,
        str,
        type,
        void,
        noreturn,
        poison,
        _,

        pub const static_len = @typeInfo(Ref).@"enum".field_names.len;

        pub fn fromIdx(index: usize) Ref {
            return @fromBackingInt(@intCast(index + static_len));
        }

        pub fn isIdx(ref: Ref) bool {
            return @backingInt(ref) >= static_len;
        }

        pub fn toString(t: Ref) []const u8 {
            switch (t) {
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
    };

    pub fn eql(a: Ref, b: Ref) bool {
        return a == b;
    }

    pub fn compatible(a: Ref, b: Ref) bool {
        if (a.kind == .poison or b.kind == .poison) return true;
        if (a.kind == .noreturn or b.kind == .noreturn) return true;
        if (eql(a, b)) return true;

        if (a.kind == .real and b.kind == .int or
            b.kind == .real and a.kind == .int)
        {
            return true;
        }

        return false;
    }

    /// returns the Least Upper Bound type between two types, asserting compatability
    pub fn common(a: Type, b: Type) Type {
        if (a.kind == .poison or b.kind == .poison) return .atomic(.poison);
        if (a.kind == .noreturn) return b;
        if (b.kind == .noreturn) return a;

        if (a.eql(b)) return a;

        if (a.kind == .real and b.kind == .int or
            b.kind == .real and a.kind == .int)
        {
            return .atomic(.real);
        }

        unreachable;
    }
};
