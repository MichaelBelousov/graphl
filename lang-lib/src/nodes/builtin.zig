//! builtin nodes

const std = @import("std");

const TypeInfo = struct {
    name: []const u8,
    field_names: []const []const u8 = &.{},
    // should structs allow constrained generic fields?
    field_types: []const Type = &.{},
};

const Type = *const TypeInfo;

const Input = struct {
    type_: Type,
    //default: Value,
};

// FIXME: separate pin value, input pin type, output pin type
const Pin = union (enum) {
    exec,
    value: Type,
    variadic: Type,
};

const Node = struct {
    context: *const align(8) anyopaque,
    // TODO: do I really need pointers? The types are all going to be well defined aggregates,
    // and the nodes too
    // FIXME: read https://pithlessly.github.io/allocgate.html, the same logic as to why zig
    // stopped using @fieldParentPtr-based polymorphism applies here to, this is slow
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

    const byte = &TypeInfo{.name="byte"};
    const bool_ = &TypeInfo{.name="bool"};

    // TODO: add slices
    const string = &TypeInfo{.name="string"};

    const vec3 = &TypeInfo{
        .name = "vec3",
        .field_names = &.{ "x", "y", "z" },
        .field_types = &.{ nums.f64_, nums.f64_, nums.f64_ },
    };
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

fn basicNode(comptime in_desc: *const struct { inputs: []const Pin = &.{}, outputs: []const Pin = &.{} }) Node {
    const NodeImpl = struct {
        const Self = @This();

        pub fn getInputs(_: Node) []const Pin {
            return in_desc.inputs;
        }

        pub fn getOutputs(_: Node) []const Pin {
            //const self: @This() = @ptr(context
            return in_desc.outputs;
        }
    };

    return Node{
        .context = @ptrCast(in_desc),
        ._getInputs = NodeImpl.getInputs,
        ._getOutputs = NodeImpl.getOutputs,
    };
}

const BreakNodeContext = struct {
    struct_type: Type,
    out_pins: []const Pin,

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.dealloc(self.out_pins);
    }
};

fn makeBreakNodeForStruct(alloc: std.mem.Allocator, in_struct_type: Type) !Node {
    var out_pins: []Pin = undefined;
    var context: *const BreakNodeContext = undefined;

    if (@inComptime()) {
        comptime var out_pins_slot: [in_struct_type.field_types.len]Pin = undefined;
        // FIXME: doesn't using a block break this?
        out_pins = &out_pins_slot;
        context = &BreakNodeContext{ .struct_type = in_struct_type, .out_pins = out_pins };
    } else {
        out_pins = try alloc.alloc(Pin, in_struct_type.field_types.len);
        for (in_struct_type.field_types, out_pins) |field_type, *out_pin| {
            out_pin.* = field_type;
        }
        context = alloc.create(BreakNodeContext{ .struct_type = in_struct_type, .out_pins = out_pins });
    }

    const NodeImpl = struct {
        const Self = @This();

        pub fn getInputs(node: Node) []const Pin {
            const ctx: *const BreakNodeContext = @ptrCast(node.context);
            return &.{Pin{.value=ctx.struct_type}};
        }

        pub fn getOutputs(node: Node) []const Pin {
            const ctx: *const BreakNodeContext = @ptrCast(node.context);
            return ctx.out_pins;
        }
    };
    return Node{
        .context = context,
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
    const @"+" = basicNode(&.{
        .inputs = &.{
            Pin{.value=primitive_types.nums.f64_},
            Pin{.value=primitive_types.nums.f64_},
        },
        .outputs = &.{ Pin{.value=primitive_types.nums.f64_} },
    });
    const @"-" = @"+";
    const max = @"+";
    const @"*" = @"+";
    const @"/" = @"+";
    const @"if" = basicNode(&.{
        .inputs = &.{
            Pin{.exec={}},
            Pin{.value=primitive_types.nums.bool_},
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
        const scene_component = &TypeInfo{.name="SceneComponent"};
        // TODO: impl enums
        const physical_material = &TypeInfo{.name="physical_material"};
        const hit_result = &TypeInfo{
            .name="hit_result",
            .field_names = &[_][]const u8{
                "location",
                "normal",
                "impact point",
                "impact normal",
                "physical material",
                "hit actor",
                "hit component",
                "hit bone name",
            },
            .field_types = &.{
                primitive_types.vec3,
                primitive_types.vec3,
                primitive_types.vec3,
                primitive_types.vec3,
                physical_material,
                actor,
                scene_component,
                primitive_types.string,
            },
        };
    };

    const nodes = struct {
        const get_actor_location = basicNode(&.{
            .inputs = &.{ Pin{.value=types.actor} },
            .outputs = &.{ Pin{.value=primitive_types.vec3} },
        });
        const custom_tick_call = basicNode(&.{
            .inputs = &.{ Pin{.value=types.actor} },
            .outputs = &.{ Pin{.value=primitive_types.vec3 } },
        });
        const custom_tick_entry = basicNode(&.{
            .outputs = &.{ Pin{.exec={}}},
        });
        const move_component_to = basicNode(&.{
            .outputs = &.{ Pin{.exec={}}},
        });

        // FIXME: use null allocator
        const break_hit_result =
            makeBreakNodeForStruct(std.testing.allocator, types.hit_result)
            catch unreachable;
        // defer @as(BreakNodeContext, @ptrCast(break_hit_result.context)).deinit(alloc);
    };
};

test "add" {
    try std.testing.expectEqual(
        builtin_nodes.@"+".getOutputs()[0].value,
        primitive_types.nums.f64_,
    );
    try std.testing.expect(temp_ue.nodes.custom_tick_entry.getOutputs()[0] == .exec);
    try std.testing.expectEqual(
        temp_ue.nodes.break_hit_result.getOutputs()[2].value,
        primitive_types.vec3
    );
}

