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
    // should structs allow constrained generic fields?
    struct_: []const struct { field: []const u8, type_: Type },
};

const Input = struct {
    type_specifier: TypeSpec,
    //default: Value,
};

const Pin = union (enum) {
    exec,
    value: TypeSpec,
    variadic: TypeSpec,
};

const Node = struct {
    context: *const anyopaque,
    // TODO: do I really need pointers? The types are all going to be well defined aggregates,
    // and the nodes too
    // FIXME: point to one table, rather than embed all methods?
    _getInputs: *const fn(Node) []const Pin,
    _getOutputs: *const fn(Node) []const Pin,

    pub fn getInputs(self: @This()) []const Pin { return self._getInputs(self); }
    pub fn getOutputs(self: @This()) []const Pin { return self._getOutputs(self); }
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

    const vec3 = TypeSpec{.struct_ = &.{
        &nums.f64,
        &nums.f64,
        &nums.f64,
    } };
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

// ignoring for now
fn returnType(builtin_node: *const Node, input_types: []const Type) Type {
    return switch (*builtin_node) {
        builtin_nodes.@"+" => resolvePeerType(input_types),
        builtin_nodes.@"-" => resolvePeerType(input_types),
    };
}

fn basicNode(comptime in_desc: struct { inputs: []const Pin = &.{}, outputs: []const Pin = &.{} }) Node {
    const NodeImpl = struct {
        desc: *const @TypeOf(in_desc) = &in_desc,
        const Self = @This();

        pub fn getInputs(_: Node) []const Pin {
            return in_desc.inputs;
        }

        pub fn getOutputs(_: Node) []const Pin {
            //const self: @This() = @ptr(context
            return in_desc.outputs;
        }
    };

    //return Node{in_desc};
    return Node{
        .context = @ptrCast(&in_desc),
        ._getInputs = NodeImpl.getInputs,
        ._getOutputs = NodeImpl.getOutputs,
    };
}

const builtin_nodes = struct {
    // const @"+" = Node{
    //     .inputs = &.{
    //         Pin{.value=primitive_types.nums.f64},
    //         Pin{.value=primitive_types.nums.f64},
    //     },
    //     .outputs = &.{ Pin{.value=primitive_types.nums.f64} },
    // };
    const @"+" = basicNode(.{
        .inputs = &.{
            Pin{.value=.{.specific = primitive_types.nums.f64_}},
            Pin{.value=.{.specific = primitive_types.nums.f64_}},
        },
        .outputs = &.{ Pin{.value=.{.specific = primitive_types.nums.f64_} }},
    });
    const @"-" = @"+";
    const max = @"+";
    const @"*" = @"+";
    const @"/" = @"+";
    const @"if" = basicNode(.{
        .inputs = &.{
            Pin{.exec={}},
            Pin{.value=.{.specific = primitive_types.nums.bool_}},
        },
        .outputs = &.{
            Pin{.exec={}},
            Pin{.exec={}},
        },
    });
    // TODO: function...
    const sequence = Node{
        .inputs = &.{ Pin{.exec={}} },
        .outputs = &.{ Pin{.variadic={}} },
    };
    // "set!":
    // "cast":
    const @"switch" = Node{
        .inputs = &.{
            Pin{.exec={}},
            Pin{.value=primitive_types.nums.f64_},
        },
        .outputs = &.{
            Pin{.variadic={}},
        },
    };
};

const temp_ue = struct {
    const types = struct {
        const actor = &TypeInfo{.name="actor"};
    };
    const nodes = struct {
        const get_actor_location = basicNode(.{
            .inputs = &.{ Pin{.value=.{.specific = types.actor}} },
            .outputs = &.{ Pin{.value=.{.specific = primitive_types.vec3 } }},
        });
        const custom_tick_call = basicNode(.{
            .inputs = &.{ Pin{.value=.{.specific = types.actor}} },
            .outputs = &.{ Pin{.value=.{.specific = primitive_types.vec3 } }},
        });
        const custom_tick_entry = basicNode(.{
            .outputs = &.{ Pin{.exec={}}},
        });
    };
};

test "add" {
    try std.testing.expectEqual(
        builtin_nodes.@"+".getOutputs()[0].value.specific,
        primitive_types.nums.f64_,
    );
    try std.testing.expect(temp_ue.nodes.custom_tick_entry.getOutputs()[0] == .exec);
}

