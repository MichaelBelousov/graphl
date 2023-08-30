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
    // FIXME: should be scoped
    /// name of the node, used as the type tag in the json format, within a particular scope
    name: []const u8,

    context: *const align(@sizeOf(usize)) anyopaque,
    // TODO: do I really need pointers? The types are all going to be well defined aggregates,
    // and the nodes too
    // FIXME: read https://pithlessly.github.io/allocgate.html, the same logic as to why zig
    // stopped using @fieldParentPtr-based polymorphism applies here to, this is needlessly slow
    _getInputs: *const fn(NodeDesc) []const Pin,
    _getOutputs: *const fn(NodeDesc) []const Pin,

    pub fn getInputs(self: @This()) []const Pin { return self._getInputs(self); }
    pub fn getOutputs(self: @This()) []const Pin { return self._getOutputs(self); }
};


pub fn Link(comptime Extra: type) type {
    return struct {
        target: *const Node(Extra),
        pin_index: u32,
        /// optional subindex (e.g. for variadic pins)
        sub_index: u32 = 0,
    };
}

pub fn Node(comptime Extra: type) type {
    return struct {
        desc: *const NodeDesc,
        extra: Extra,
        comment: ?[]const u8 = null,
        out_links: []Link(Extra) = &.{},

        pub const ExecLinkIterator = struct {
            index: usize = 0,
            node: *const Node,

            pub fn next(self: @This()) ?Link(Extra) {
                while (self.index < self.node.out_links.len) : (self.index += 1) {
                    const is_exec = self.node.desc.getOutputs()[self.index] == .exec;
                    if (is_exec) {
                        self.index += 1;
                        return self.node.out_links[self.index];
                    }
                }

                return null;
            }

            pub fn hasNext(self: @This()) bool {
                return self.index < self.node.out_links.len;
            }
        };

        pub fn iter_out_exec_links(self: @This()) ExecLinkIterator {
            return ExecLinkIterator{ .node = self };
        }
    };
}

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

    // pub fn list(_: @This(), t: Type, fallback_alloc: std.mem.Allocator) Type {
    //     // FIXME: which allocator?
    //     const name = if (@inComptime())
    //         std.fmt.comptimePrint("list({s})", t.name)
    //         else std.fmt.allocPrint(std.testing.failing_allocator, "list({s})", t.name);

    //     // can I just run an allocator at comptime? is that how zig is supposed to work?
    //     comptime var slot: TypeInfo = undefined;
    //     var new_type = fallback_alloc.create(TypeInfo);
    //     new_type.* = TypeInfo{
    //         .name = std.fmt.allocPrint(std.testing.failing_allocator, "list({s})", t.name),
    //     };

    //     //env.types.put(std.testing.failing_allocator, t.name, new_type);
    // }
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
    name: []const u8,
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
        .name = in_desc.name,
        .context = @ptrCast(in_desc),
        ._getInputs = NodeImpl.getInputs,
        ._getOutputs = NodeImpl.getOutputs,
    };
}

// FIXME: isn't this going to be illegal? https://github.com/ziglang/zig/issues/7396
// FIXME: move to own file
fn comptimeAllocOrFallback(fallback_allocator: std.mem.Allocator, comptime T: type, comptime count: usize) std.mem.Allocator.Error![]T {
    comptime var comptime_slot: [if (@inComptime()) count else 0]T = undefined;
    return if (@inComptime()) &comptime_slot
         else try fallback_allocator.alloc(T, count);
}

// after reviewing comptime semantics, not sure if current compiler blocks it, but this will be illegal
fn comptimeCreateOrFallback(fallback_allocator: std.mem.Allocator, comptime T: type) std.mem.Allocator.Error!*T {
    comptime var comptime_slot: T = undefined;
    return if (@inComptime()) &comptime_slot
         else try fallback_allocator.create(T);
}

pub const VarNodes = struct {
    get: NodeDesc,
    set: NodeDesc,

    fn init(alloc: std.mem.Allocator, var_name: []const u8, var_type: Type) !VarNodes {
        // FIXME: test and plug non-comptime alloc leaks
        const getterOutputs = try comptimeAllocOrFallback(alloc, Pin, 1);
        getterOutputs[0] = Pin{.value=var_type};

        const getter_name =
            if (@inComptime()) std.fmt.comptimePrint("get_{s}", .{var_name})
            else std.fmt.allocPrint(alloc, "get_{s}", .{var_name});

        const setterInputs = try comptimeAllocOrFallback(alloc, Pin, 2);
        setterInputs[0] = .exec;
        setterInputs[1] = Pin{.value=var_type};

        const setterOutputs = try comptimeAllocOrFallback(alloc, Pin, 2);
        setterOutputs[0] = .exec;
        setterOutputs[1] = Pin{.value=var_type};

        const setter_name =
            if (@inComptime()) std.fmt.comptimePrint("get_{s}", .{var_name})
            else std.fmt.allocPrint(alloc, "get_{s}", .{var_name});

        return VarNodes{
            .get = basicNode(&.{
                .name = getter_name,
                .outputs = getterOutputs,
            }),
            .set = basicNode(&.{
                .name = setter_name,
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

    const name =
        if (@inComptime()) std.fmt.comptimePrint("break_{s}", .{in_struct_type.name})
        else std.fmt.allocPrint(alloc, "break_{s}", .{in_struct_type.name});

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
        .name = name,
        .context = context,
        ._getInputs = NodeImpl.getInputs,
        ._getOutputs = NodeImpl.getOutputs,
    };
}

pub const builtin_nodes = (struct {
    @"+": NodeDesc = basicNode(&.{
        .name = "+",
        .inputs = &.{
            Pin{.value=primitive_types.f64_}, Pin{.value=primitive_types.f64_}
        },
        .outputs = &.{ Pin{.value=primitive_types.f64_} }
    }),
    @"-": NodeDesc = basicNode(&.{
        .name = "-",
        .inputs = &.{
            Pin{.value=primitive_types.f64_}, Pin{.value=primitive_types.f64_}
        },
        .outputs = &.{ Pin{.value=primitive_types.f64_} }
    }),
    max: NodeDesc = basicNode(&.{
        .name = "max",
        .inputs = &.{
            Pin{.value=primitive_types.f64_}, Pin{.value=primitive_types.f64_}
        },
        .outputs = &.{ Pin{.value=primitive_types.f64_} }
    }),
    min: NodeDesc = basicNode(&.{
        .name = "max",
        .inputs = &.{
            Pin{.value=primitive_types.f64_}, Pin{.value=primitive_types.f64_}
        },
        .outputs = &.{ Pin{.value=primitive_types.f64_} }
    }),
    @"*": NodeDesc = basicNode(&.{
        .name = "*",
        .inputs = &.{
            Pin{.value=primitive_types.f64_}, Pin{.value=primitive_types.f64_}
        },
        .outputs = &.{ Pin{.value=primitive_types.f64_} }
    }),
    @"/": NodeDesc = basicNode(&.{
        .name = "/",
        .inputs = &.{
            Pin{.value=primitive_types.f64_}, Pin{.value=primitive_types.f64_}
        },
        .outputs = &.{ Pin{.value=primitive_types.f64_} }
    }),
    @"if": NodeDesc = basicNode(&.{
        .name = "if",
        .inputs = &.{ .exec, Pin{.value=primitive_types.bool_} },
        .outputs = &.{ .exec, .exec },
    }),
    // TODO: function...
    sequence: NodeDesc = basicNode(&.{
        .name = "sequence",
        .inputs = &.{ Pin{.exec={}} },
        .outputs = &.{ Pin{.variadic=.exec} },
    }),

    @"set!": NodeDesc = basicNode(&.{
        .name = "set!",
        // FIXME: needs to be generic/per variable
        .inputs = &.{ Pin{.exec={}}, Pin{.value=primitive_types.f64_} },
        .outputs = &.{ .exec, Pin{.value=primitive_types.f64_} },
    }),

    // "cast":
    @"switch": NodeDesc = basicNode(&.{
        .name = "switch",
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
        
        actor: Type = actor,
        // FIXME: use list(actor)
        actor_list: Type = &TypeInfo{.name="list(actor)"},
        scene_component: Type = &TypeInfo{.name="SceneComponent"},
        trace_channels: Type = &TypeInfo{.name="trace_channels"},
        draw_debug_types: Type = &TypeInfo{.name="draw_debug_types"},
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
        // const current_spawn_point = VarNodes.init(std.testing.failing_allocator, "current_spawn_point", types.scene_component)
        //     catch unreachable;
        // const drone_state = VarNodes.init(std.testing.failing_allocator, "drone_state", types.scene_component)
        //     catch unreachable;
        // const mesh = VarNodes.init(std.testing.failing_allocator, "mesh", types.scene_component)
        //     catch unreachable;
        // const over_time = VarNodes.init(std.testing.failing_allocator, "over-time", types.scene_component)
        //     catch unreachable;
        // const speed = VarNodes.init(std.testing.failing_allocator, "mesh", primitive_types.f32_)
        //     catch unreachable;

        custom_tick_call: NodeDesc = basicNode(&.{
            .name = "CustomTickCall",
            .inputs = &.{ Pin{.value=types.actor} },
            .outputs = &.{ Pin{.value=primitive_types.vec3 } },
        }),

        // FIXME: remove and just have an entry
        custom_tick_entry: NodeDesc = basicNode(&.{
            .name = "CustomTickEntry",
            .outputs = &.{ Pin{.exec={}}},
        }),

        move_component_to: NodeDesc = basicNode(&.{
            .name = "MoveComponentTo",
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

        // FIXME: use non-testing failing allocator
        break_hit_result: NodeDesc =
            makeBreakNodeForStruct(std.testing.failing_allocator, types.hit_result)
            catch unreachable,

        get_capsule_component: NodeDesc = capsule_component.get,
        set_capsule_component: NodeDesc = capsule_component.set,

        // FIXME: un break
        // get_current_spawn_point: NodeDesc = current_spawn_point.get,
        // set_current_spawn_point: NodeDesc = current_spawn_point.set,

        // get_drone_state: NodeDesc = drone_state.get,
        // set_drone_state: NodeDesc = drone_state.set,

        // get_mesh: NodeDesc = mesh.get,
        // set_mesh: NodeDesc = mesh.set,

        // get_over_time: NodeDesc = over_time.get,
        // set_over_time: NodeDesc = over_time.set,

        // get_speed: NodeDesc = speed.get,
        // set_speed: NodeDesc = speed.set,

        cast: NodeDesc = basicNode(&.{
            .name = "cast",
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
            .name = "do-once",
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
            .name = "fake-switch",
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
            .name = "get-actor-location",
            .inputs = &.{ Pin{.value=types.actor} },
            .outputs = &.{ Pin{.value=primitive_types.vec3} },
        }),

        get_actor_rotation: NodeDesc = basicNode(&.{
            .name = "get-actor-rotation",
            .inputs = &.{ Pin{.value=types.actor} },
            .outputs = &.{ Pin{.value=primitive_types.vec4} },
        }),

        get_socket_location: NodeDesc = basicNode(&.{
            .name = "get-socket-location",
            .inputs = &.{
                Pin{.value=types.actor},
                Pin{.value=primitive_types.string},
            },
            .outputs = &.{ Pin{.value=primitive_types.vec3} },
        }),

        fake_sequence_3: NodeDesc = basicNode(&.{
            .name = "fake-sequence-3",
            .inputs = &.{ .exec },
            .outputs = &.{ .exec, .exec, .exec },
        }),

        single_line_trace_by_channel: NodeDesc = basicNode(&.{
            .name = "single-line-trace-by-channel",
            .inputs = &.{
                .exec,
                Pin{.value=primitive_types.vec3}, // start
                Pin{.value=primitive_types.vec3}, // end
                Pin{.value=types.trace_channels}, // channel
                Pin{.value=primitive_types.bool_}, // trace-complex
                Pin{.value=types.actor_list}, // actors-to-ignore
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
            .name = "vector-length",
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
                const type_ = @field(types, t.name);
                try env.types.put(alloc, type_.name, type_.*);
            }
        }

        inline for (&.{builtin_nodes, temp_ue.nodes}) |nodes| {
            const nodes_fields = @typeInfo(@TypeOf(nodes)).Struct.fields;
            try env.nodes.ensureTotalCapacity(alloc, nodes_fields.len);
            inline for (nodes_fields) |n| {
                const node = @field(nodes, n.name);
                try env.nodes.put(alloc, node.name, node);
            }
        }

        return env;
    }

    pub fn makeNode(self: @This(), kind: []const u8, extra: anytype) ?Node(@TypeOf(extra)) {
        return if (self.nodes.getPtr(kind)) |desc|
            .{ .desc = desc, .extra = extra }
        else
            null;
    }
};

test "env" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(env.types.contains("u32"));
}
