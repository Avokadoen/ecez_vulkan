const std = @import("std");

pub fn ComponentTypeArrayToTupleType(comptime components: []const type) type {
    const Tuple = std.meta.Tuple(&[_]type{type} ** components.len);
    return Tuple;
}

pub fn componentTypeArrayToTuple(comptime components: []const type) ComponentTypeArrayToTupleType(components) {
    const Tuple = ComponentTypeArrayToTupleType(components);
    comptime var tuple: Tuple = undefined;
    inline for (components, 0..) |Component, comp_index| {
        tuple[comp_index] = Component;
    }
    return tuple;
}
