//! builtin nodes

const std = @import("std");

pub const TypeInfo = struct {
    name: []const u8,
    field_names: []const []const u8 = &.{},
    // should structs allow constrained generic fields?
    field_types: []const Type = &.{},
};

pub const Type = *const TypeInfo;

pub const Input = struct {
    type_: Type,
    //default: Value,
};

// FIXME: merge somehow?
pub const VarPin = union (enum) {
    exec,
    value: Type,

    fn toPin(self: @This()) Pin {
        return switch (self) {
            .exec => .exec,
            .value => |v| Pin{.value=v},
        };
    }
};

// FIXME: separate pin value, input pin type, output pin type
pub const Pin = union (enum) {
    exec,
    value: Type,
    variadic: VarPin,
};

pub const NodeDesc = struct {
    context: *const align(8) anyopaque,
    // TODO: do I really need pointers? The types are all going to be well defined aggregates,
    // and the nodes too
    // FIXME: read https://pithlessly.github.io/allocgate.html, the same logic as to why zig
    // stopped using @fieldParentPtr-based polymorphism applies here to, this is needlessly slow
    _getInputs: *const fn(NodeDesc) []const Pin,
    _getOutputs: *const fn(NodeDesc) []const Pin,

    pub fn getInputs(self: @This()) []const Pin { return self._getInputs(self); }
    pub fn getOutputs(self: @This()) []const Pin { return self._getOutputs(self); }
};

pub const Link = struct {
    pinIndex: u32,
    /// optional subindex (e.g. for variadic pins)
    subIndex: u32 = 0,
};

pub const Node = struct {
    desc: *const NodeDesc,
    comment: ?[]const u8,
    outLinks: []Link,
};

pub const primitive_types = (struct {
    const f64_ = &TypeInfo{.name="f64"};

    // nums
    i32_: Type = &TypeInfo{.name="i32"},
    i64_: Type = &TypeInfo{.name="i64"},
    u32_: Type = &TypeInfo{.name="u32"},
    u64_: Type = &TypeInfo{.name="u64"},
    f32_: Type = &TypeInfo{.name="f32"},
    f64_: Type = f64_,

    byte: Type = &TypeInfo{.name="byte"},
    bool_: Type = &TypeInfo{.name="bool"},
    rune_: Type = &TypeInfo{.name="rune"},

    string: Type = &TypeInfo{.name="string"},
    vec3: Type = &TypeInfo{
        .name = "vec3",
        .field_names = &.{ "x", "y", "z" },
        .field_types = &.{ f64_, f64_, f64_ },
    },
    vec4: Type = &TypeInfo{
        .name = "vec4",
        .field_names = &.{ "x", "y", "z", "w" },
        .field_types = &.{ f64_, f64_, f64_, f64_ },
    },

    pub fn list(t: Type, env: *Env) Type {
        // FIXME: which allocator?
        var new_type = std.testing.failing_allocator.create(TypeInfo);
        new_type.* = TypeInfo{
            .name = std.fmt.allocPrint(std.testing.failing_allocator, "list({s})", t.name),
        };
        env.types.put(std.testing.failing_allocator, t.name, new_type);
    }
}){};


/// lisp-like tree, first is value, rest are children
// const num_type_hierarchy = .{
//     primitive_types.f64_,
//     .{ primitive_types.f32_,
//         .{ primitive_types.i64_,
//             .{ primitive_types.i32_ },
//             .{ primitive_types.u32_} },
//         .{ primitive_types.u64_, } } };

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
pub fn returnType(builtin_node: *const NodeDesc, input_types: []const Type) Type {
    return switch (*builtin_node) {
        builtin_nodes.@"+" => resolvePeerType(input_types),
        builtin_nodes.@"-" => resolvePeerType(input_types),
    };
}

const BasicNodeDesc = struct {
    inputs: []const Pin = &.{},
    outputs: []const Pin = &.{}
};

/// caller owns memory!
pub fn basicNode(in_desc: *const BasicNodeDesc) NodeDesc {
    const NodeImpl = struct {
        const Self = @This();

        pub fn getInputs(node: NodeDesc) []const Pin {
            const desc: @TypeOf(in_desc) = @ptrCast(node.context);
            return desc.inputs;
        }

        pub fn getOutputs(node: NodeDesc) []const Pin {
            const desc: @TypeOf(in_desc) = @ptrCast(node.context);
            return desc.outputs;
        }
    };

    return NodeDesc{
        .context = @ptrCast(in_desc),
        ._getInputs = NodeImpl.getInputs,
        ._getOutputs = NodeImpl.getOutputs,
    };
}

// FIXME: move to own file
fn comptimeAllocOrFallback(fallback_allocator: std.mem.Allocator, comptime T: type, comptime count: usize) std.mem.Allocator.Error![]T {
    comptime var comptime_slot: [if (@inComptime()) count else 0]T = undefined;
    return if (@inComptime()) &comptime_slot
         else try fallback_allocator.alloc(T, count);
}

pub const VarNodes = struct {
    get: NodeDesc,
    set: NodeDesc,

    fn init(alloc: std.mem.Allocator, var_name: []const u8, var_type: Type) !VarNodes {
        // FIXME: node pins should have names
        _ = var_name;

        const getterOutputs = try comptimeAllocOrFallback(alloc, Pin, 1);
        getterOutputs[0] = Pin{.value=var_type};

        const setterInputs = try comptimeAllocOrFallback(alloc, Pin, 2);
        setterInputs[0] = .exec;
        setterInputs[1] = Pin{.value=var_type};

        const setterOutputs = try comptimeAllocOrFallback(alloc, Pin, 2);
        setterOutputs[0] = .exec;
        setterOutputs[1] = Pin{.value=var_type};

        return .{
            .get = basicNode(.{
                .outputs = getterOutputs,
            }),
            .set = basicNode(.{
                .inputs = setterInputs,
                .outputs = setterOutputs,
            }),
        };
    }
};

pub const BreakNodeContext = struct {
    struct_type: Type,
    out_pins: []const Pin,

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.dealloc(self.out_pins);
    }
};

pub fn makeBreakNodeForStruct(alloc: std.mem.Allocator, in_struct_type: Type) !NodeDesc {
    const out_pins = try comptimeAllocOrFallback(alloc, Pin, in_struct_type.field_types.len);
    for (in_struct_type.field_types, out_pins) |field_type, *out_pin| {
        out_pin.* = Pin{.value=field_type};
    }

    const context: *const BreakNodeContext =
        if (@inComptime()) &BreakNodeContext{ .struct_type = in_struct_type, .out_pins = out_pins }
        else try alloc.create(BreakNodeContext{ .struct_type = in_struct_type, .out_pins = out_pins });

    const NodeImpl = struct {
        const Self = @This();

        pub fn getInputs(node: NodeDesc) []const Pin {
            const ctx: *const BreakNodeContext = @ptrCast(node.context);
            return &.{Pin{.value=ctx.struct_type}};
        }

        pub fn getOutputs(node: NodeDesc) []const Pin {
            const ctx: *const BreakNodeContext = @ptrCast(node.context);
            return ctx.out_pins;
        }
    };
    return NodeDesc{
        .context = context,
        ._getInputs = NodeImpl.getInputs,
        ._getOutputs = NodeImpl.getOutputs,
    };
}

// FIXME: nodes need to know their names
pub const genericMathOp = basicNode(&.{
    .inputs = &.{
        Pin{.value=primitive_types.f64_},
        Pin{.value=primitive_types.f64_},
    },
    .outputs = &.{ Pin{.value=primitive_types.f64_} },
});

pub const builtin_nodes = (struct {
    @"+": NodeDesc = genericMathOp,
    @"-": NodeDesc = genericMathOp,
    max: NodeDesc = genericMathOp,
    min: NodeDesc = genericMathOp,
    @"*": NodeDesc = genericMathOp,
    @"/": NodeDesc = genericMathOp,
    @"if": NodeDesc = basicNode(&.{
        .inputs = &.{
            Pin{.exec={}},
            Pin{.value=primitive_types.bool_},
        },
        .outputs = &.{
            Pin{.exec={}},
            Pin{.exec={}},
        },
    }),
    // TODO: function...
    sequence: NodeDesc = basicNode(&.{
        .inputs = &.{ Pin{.exec={}} },
        .outputs = &.{ Pin{.variadic=.exec} },
    }),
    // "set!":
    // "cast":
    @"switch": NodeDesc = basicNode(&.{
        .inputs = &.{
            Pin{.exec={}},
            Pin{.value=primitive_types.f64_},
        },
        .outputs = &.{
            Pin{.variadic=.exec},
        },
    }),
}){};

pub const temp_ue = struct {
    const types = (struct {
        // TODO: impl enums
        const physical_material: Type = &TypeInfo{.name="physical_material"};
        const actor: Type = &TypeInfo{.name="actor"};
        const scene_component: Type = &TypeInfo{.name="SceneComponent"};

        actor: Type = &TypeInfo{.name="actor"},
        scene_component: Type = &TypeInfo{.name="SceneComponent"},
        physical_material: Type = physical_material,
        hit_result: Type = &TypeInfo{
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
        },
    }){};

    const nodes = (struct {
        // TODO: replace with live vars
        const capsule_component = VarNodes.init(std.testing.failing_allocator, "capsule_component", types.scene_component)
            catch unreachable;
        const current_spawn_point = VarNodes.init(std.testing.failing_allocator, "current_spawn_point", types.scene_component)
            catch unreachable;
        const drone_state = VarNodes.init(std.testing.failing_allocator, "drone_state", types.scene_component)
            catch unreachable;
        const mesh = VarNodes.init(std.testing.failing_allocator, "mesh", types.scene_component)
            catch unreachable;
        const over_time = VarNodes.init(std.testing.failing_allocator, "over-time", types.scene_component)
            catch unreachable;
        const speed = VarNodes.init(std.testing.failing_allocator, "mesh", primitive_types.f32_)
            catch unreachable;

        custom_tick_call: NodeDesc = basicNode(&.{
            .inputs = &.{ Pin{.value=types.actor} },
            .outputs = &.{ Pin{.value=primitive_types.vec3 } },
        }),

        custom_tick_entry: NodeDesc = basicNode(&.{
            .outputs = &.{ Pin{.exec={}}},
        }),

        move_component_to: NodeDesc = basicNode(&.{
            .inputs = &.{
                // FIXME: what about pin names? :/
                .exec,
                .exec,
                .exec,
                Pin{.value=types.scene_component},
                Pin{.value=primitive_types.vec3},
                Pin{.value=primitive_types.vec4},
                Pin{.value=primitive_types.bool_},
                Pin{.value=primitive_types.bool_},
                Pin{.value=primitive_types.f32_},
            },
            .outputs = &.{ Pin{.exec={}}},
        }),

        // FIXME: use null allocator?
        break_hit_result: NodeDesc =
            makeBreakNodeForStruct(std.testing.failing_allocator, types.hit_result)
            catch unreachable,

        get_capsule_component: NodeDesc = capsule_component.get,
        set_capsule_component: NodeDesc = capsule_component.set,

        get_current_spawn_point: NodeDesc = current_spawn_point.get,
        set_current_spawn_point: NodeDesc = current_spawn_point.set,

        get_drone_state: NodeDesc = drone_state.get,
        set_drone_state: NodeDesc = drone_state.set,

        get_mesh: NodeDesc = mesh.get,
        set_mesh: NodeDesc = mesh.set,

        get_over_time: NodeDesc = over_time.get,
        set_over_time: NodeDesc = over_time.set,

        get_speed: NodeDesc = speed.get,
        set_speed: NodeDesc = speed.set,

        cast: NodeDesc = basicNode(&.{
            .inputs = &. {
                .exec,
                Pin{.value=types.actor},
            },
            .outputs = &.{
                .exec,
                .exec,
                Pin{.value=types.actor},
            },
        }),

        do_once: NodeDesc = basicNode(&.{
            .inputs = &. {
                .exec,
                .exec, // reset
                Pin{.value=primitive_types.bool_}, // start closed
            },
            .outputs = &.{
                Pin{.exec={}}, // completed
            },
        }),

        fake_switch: NodeDesc = basicNode(&.{
            .inputs = &.{
                .exec,
                Pin{.value=primitive_types.f64_},
            },
            .outputs = &.{
                .exec, // move to player
                .exec, // move up
                .exec, // dead
            },
        }),

        get_actor_location: NodeDesc = basicNode(&.{
            .inputs = &.{ Pin{.value=types.actor} },
            .outputs = &.{ Pin{.value=primitive_types.vec3} },
        }),

        get_actor_rotation: NodeDesc = basicNode(&.{
            .inputs = &.{ Pin{.value=types.actor} },
            .outputs = &.{ Pin{.value=primitive_types.vec4} },
        }),

        get_socket_location: NodeDesc = basicNode(&.{
            .inputs = &.{
                Pin{.value=types.actor},
                Pin{.value=primitive_types.string},
            },
            .outputs = &.{ Pin{.value=primitive_types.vec3} },
        }),

        if_: NodeDesc = basicNode(&.{
            .inputs = &. {
                .exec,
                Pin{.value=primitive_types.bool_},
            },
            .outputs = &.{
                .exec, // then
                .exec, // else
            },
        }),

        fake_sequence_3: NodeDesc = basicNode(&.{
            .inputs = &.{ .exec },
            .outputs = &.{ .exec, .exec, .exec },
        }),

        single_line_trace_by_channel: NodeDesc = basicNode(&.{
            .inputs = &.{
                .exec,
                Pin{.value=primitive_types.vec3}, // start
                Pin{.value=primitive_types.vec3}, // end
                Pin{.value=types.trace_channels}, // channel
                Pin{.value=primitive_types.bool_}, // trace-complex
                Pin{.value=primitive_types.list(types.actor)}, // actors-to-ignore
                Pin{.value=types.draw_debug_types}, // draw-debug-type (default 'none)
                Pin{.value=primitive_types.bool_}, // ignore-self (default false)
            },
            .outputs = &.{
                .exec,
                Pin{.value=types.hit_result}, // out hit
                Pin{.value=primitive_types.bool_}, // did hit
            },
        }),

        vector_length: NodeDesc = basicNode(&.{
            .inputs = &.{ Pin{.value=primitive_types.vec3} },
            .outputs = &.{ Pin{.value=primitive_types.f64_} },
        }),
    }){};
};

fn expectEqualTypes(actual: Type, expected: Type) !void {
    if (actual != expected) {
        // TODO: implement format for types
        std.debug.print("Expected '{s}'<{*}> but got '{s}'<{*}>\n", .{actual.name, actual, expected.name, expected});
        return error.TestFail;
    }
}

test "node types" {
    try std.testing.expectEqual(
        builtin_nodes.@"+".getOutputs()[0].value,
        primitive_types.f64_,
    );
    try std.testing.expect(temp_ue.nodes.custom_tick_entry.getOutputs()[0] == .exec);
    try expectEqualTypes(
        temp_ue.nodes.break_hit_result.getOutputs()[2].value,
        primitive_types.vec3
    );
}

pub const Env = struct {
    types: std.StringHashMapUnmanaged(TypeInfo),
    nodes: std.StringHashMapUnmanaged(NodeDesc),
    alloc: std.mem.Allocator,

    pub fn deinit(self: *@This()) void {
        self.types.clearAndFree(self.alloc);
        self.nodes.clearAndFree(self.alloc);
    }

    pub fn initDefault(alloc: std.mem.Allocator) !@This() {
        var env = @This(){
            .types = std.StringHashMapUnmanaged(TypeInfo){},
            // could be macro, function, operator
            .nodes = std.StringHashMapUnmanaged(NodeDesc){},
            .alloc = alloc,
        };

        inline for (&.{primitive_types, temp_ue.types}) |types| {
            const types_fields = @typeInfo(@TypeOf(types)).Struct.fields;
            try env.types.ensureTotalCapacity(alloc, types_fields.len);
            inline for (types_fields) |t| {
                try env.types.put(alloc, t.name, @field(types, t.name).*);
            }
        }

        inline for (&.{builtin_nodes, temp_ue.nodes}) |nodes| {
            const nodes_fields = @typeInfo(@TypeOf(nodes)).Struct.fields;
            try env.nodes.ensureTotalCapacity(alloc, nodes_fields.len);
            inline for (nodes_fields) |n| {
                try env.nodes.put(alloc, n.name, @field(nodes, n.name));
            }
        }

        return env;
    }
};

test "env" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(env.types.contains("u32_"));
}
