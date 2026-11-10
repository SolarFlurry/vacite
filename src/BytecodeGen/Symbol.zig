const std = @import("std");

value: Value,

pub const Value = union(enum) {
    /// index into constants array
    constant: usize,
    /// allocated register
    reg: u8,
};
