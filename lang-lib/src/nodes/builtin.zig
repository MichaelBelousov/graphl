//! builtin nodes

const std = @import("std");

const TypeInfo = struct {
    name: []const u8,
};

const Type = *const TypeInfo;

const TypeSpec = union {
    specific: Type,
    //enum_values: []const enum_value,
    union_: []const TypeInfo,
    struct_: []const TypeInfo,
};

const Input = struct {
    type_specifier: TypeSpec,
    //default: Value,
};

const Pin = union (enum) {
    exec,
    input: TypeSpec,
    variadic: TypeSpec,
};

// TODO: handle switch
const Node = struct {
    type_: Type,
    pins: []const Pin,
};

const primitive_types = struct {
    const nums = struct {
        const i32_ = &TypeInfo{.name="i32"};
        const i64_ = &TypeInfo{.name="i64"};
        const u32_ = &TypeInfo{.name="u32"};
        const u64_ = &TypeInfo{.name="u64"};
        const f32_ = &TypeInfo{.name="f32"};
        const f64_ = &TypeInfo{.name="f64"};
    };

    const string = &TypeInfo{.name="string"};
    const byte = &TypeInfo{.name="byte"};
    const bool_ = &TypeInfo{.name="bool"};
};

/// lisp-like tree, first is value, rest are children
// const num_type_hierarchy = .{
//     primitive_types.nums.f64_,
//     .{ primitive_types.nums.f32_,
//         .{ primitive_types.nums.i64_,
//             .{ primitive_types.nums.i32_ },
//             .{ primitive_types.nums.u32_} },
//         .{ primitive_types.nums.u64_, } } };

// comptime {
//     fn countLeg(comptime types: anytype) usize {
//         var result = 1;
//         for (types[1..]) |leg|
//             result += countLeg(leg);
//         return result;
//     }
//     const num_type_hierarchy_leg_count = countLeg(num_type_hierarchy);

//     var num_type_hierarchy_legs: [num_type_hierarchy_leg_count][2]Type = undefined;
//     fn populateLegs(
//         in_num_type_hierarchy_legs: *@TypeOf(num_type_hierarchy_legs),
//         index: *usize,
//         curr_node: @TypeOf(num_type_hierarchy),
//     ) void {
//         for (curr_node) |leg|
//             result += countLeg(leg);
//         index.* += 1;
//         populateLegs()
//     }
//     populateLegs(0, &num_type_hierarchy);
// }

fn resolvePeerType(types: []const Type) Type {
    _ = types;
    const Local = struct { fn resolvePair(t: Type, u: Type) Type {
        _ = t;
        _ = u;
    } };
    _ = Local;
    //std.meta.window
    // for (types) |t| {

    // }
}


test "peer resolve types" {

}

fn returnType(builtin_node: *const Node, input_types: []const Type) Type {
    return switch (*builtin_node) {
        builtin_nodes.@"+" => resolvePeerType(input_types),
        builtin_nodes.@"-" => resolvePeerType(input_types),
    };
}

const builtin_nodes = struct {
    const @"+" = Node{};
    // "max":
    // "+":
    // "-":
    // "*":
    // "/":
    // "if":
    // "sequence":
    // "set!":
    // "cast":
    // "switch":
};

