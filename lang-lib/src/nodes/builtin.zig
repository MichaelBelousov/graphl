//! builtin nodes

const std = @import("std");

const failing_allocator = std.testing.failing_allocator;

pub const TypeInfo = struct {
    name: []const u8,
    field_names: []const []const u8 = &.{},
    // should structs allow constrained generic fields?
    field_types: []const Type = &.{},
};

pub const Type = *const TypeInfo;

pub const PrimitivePin = union (enum) {
    exec,
    value: Type,
};

pub const exec = Pin{.primitive=.exec};

// FIXME: replace with or convert to sexp?
pub const Value = union (enum) {
    // FIXME: handle integers separately? (e.g. check for '.' in token)
    number: f64,
    string: []const u8,
    bool: bool,
    null: void,
    symbol: []const u8,
};

pub const Pin = union (enum) {
    primitive: PrimitivePin,
    variadic: PrimitivePin,

    pub fn isExec(self: @This()) bool {
        return self == .primitive and self.primitive == .exec;
    }
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

    const FlowType = enum {
        functionCall,
        pure,
        simpleBranch,
    };

    // FIXME: pre-calculate this at construction (or cache it?)
    pub fn isSimpleBranch(self: @This()) bool {
        const is_branch = std.mem.eql(u8, node.target.desc.name, "if");
        if (is_branch) {
            std.debug.assert(node.target.desc.getOutputs().len == 2);
            std.debug.assert(node.target.desc.getOutputs()[0].isExec());
            std.debug.assert(node.target.desc.getOutputs()[1].isExec());
        }
        return is_branch;
    }

    pub fn isFunctionCall(self: @This()) bool {
        return !self.isBranch();
    }
};

pub fn GraphTypes(comptime Extra: type) type {
    return struct {
        pub const Link = struct {
            target: *const Node,
            pin_index: u32,
            /// optional subindex (e.g. for variadic pins)
            sub_index: u32 = 0,
        };

        pub const Input = union (enum) {
            link: Link,
            value: Value,
        };

        pub const Output = struct {
            link: Link,
        };

        pub const Node = struct {
            desc: *const NodeDesc,
            extra: Extra,
            comment: ?[]const u8 = null,
            // FIMXE: how do we handle default inputs?
            inputs: []Input = &.{},
            outputs: []?Output = &.{},

            // FIXME: replace this, each node belongs to a well defined flow control archetype
            pub const OutExecIterator = struct {
                index: usize = 0,
                node: *const Node,

                pub fn next(self: @This()) ?Link {
                    while (self.index < self.node.outputs.len) : (self.index += 1) {
                        const output = self.node.desc.getOutputs()[self.index];
                        const is_exec = output == .primitive and output.primitive == .exec;
                        if (is_exec) {
                            self.index += 1;
                            return self.node.outputs[self.index];
                        }
                    }

                    return null;
                }

                pub fn hasNext(self: @This()) bool {
                    return self.index < self.node.outputs.len;
                }
            };

            pub fn iter_out_execs(self: @This()) OutExecIterator {
                return OutExecIterator{ .node = self };
            }
        };
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
    //         else std.fmt.allocPrint(failing_allocator, "list({s})", t.name);

    //     // can I just run an allocator at comptime? is that how zig is supposed to work?
    //     comptime var slot: TypeInfo = undefined;
    //     var new_type = fallback_alloc.create(TypeInfo);
    //     new_type.* = TypeInfo{
    //         .name = std.fmt.allocPrint(failing_allocator, "list({s})", t.name),
    //     };

    //     //env.types.put(failing_allocator, t.name, new_type);
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

pub const VarNodes = struct {
    get: NodeDesc,
    set: NodeDesc,

    fn init(alloc: std.mem.Allocator, var_name: []const u8, var_type: Type) !VarNodes {
        // FIXME: test and plug non-comptime alloc leaks
        comptime var getter_outputs_slot: [if (@inComptime()) 1 else 0]Pin = undefined;
        const getter_outputs = if (@inComptime()) &getter_outputs_slot
             else try alloc.alloc(Pin, 1);
        getter_outputs[0] = Pin{.primitive=.{.value=var_type}};

        const getter_name =
            if (@inComptime()) std.fmt.comptimePrint("get_{s}", .{var_name})
            else std.fmt.allocPrint(alloc, "get_{s}", .{var_name});

        // FIXME: is there a better way to do this?
        comptime var setter_inputs_slot: [if (@inComptime()) 2 else 0]Pin = undefined;
        const setter_inputs = if (@inComptime()) &setter_inputs_slot
             else try alloc.alloc(Pin, 2);
        setter_inputs[0] = Pin{.primitive=.exec};
        setter_inputs[1] = Pin{.primitive=.{.value=var_type}};

        comptime var setter_outputs_slot: [if (@inComptime()) 2 else 0]Pin = undefined;
        const setter_outputs = if (@inComptime()) &setter_outputs_slot
             else try alloc.alloc(Pin, 2);
        setter_outputs[0] = Pin{.primitive=.exec};
        setter_outputs[1] = Pin{.primitive=.{.value=var_type}};

        const setter_name =
            if (@inComptime()) std.fmt.comptimePrint("get_{s}", .{var_name})
            else std.fmt.allocPrint(alloc, "get_{s}", .{var_name});

        return VarNodes{
            .get = basicNode(&.{
                .name = getter_name,
                .outputs = getter_outputs,
            }),
            .set = basicNode(&.{
                .name = setter_name,
                .inputs = setter_inputs,
                .outputs = setter_outputs,
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
    var out_pins_slot: [if (@inComptime()) in_struct_type.field_types.len else 0]Pin = undefined;
    var out_pins = if (@inComptime()) &out_pins_slot else try alloc.alloc(Pin, in_struct_type.field_types.len);

    for (in_struct_type.field_types, out_pins) |field_type, *out_pin| {
        out_pin.* = Pin{.primitive=.{.value=field_type}};
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
            return &.{Pin{.primitive=.{.value=ctx.struct_type}}};
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
            Pin{.primitive=.{.value=primitive_types.f64_}}, Pin{.primitive=.{.value=primitive_types.f64_}}
        },
        .outputs = &.{ Pin{.primitive=.{.value=primitive_types.f64_}} }
    }),
    @"-": NodeDesc = basicNode(&.{
        .name = "-",
        .inputs = &.{
            Pin{.primitive=.{.value=primitive_types.f64_}}, Pin{.primitive=.{.value=primitive_types.f64_}}
        },
        .outputs = &.{ Pin{.primitive=.{.value=primitive_types.f64_}} }
    }),
    max: NodeDesc = basicNode(&.{
        .name = "max",
        .inputs = &.{
            Pin{.primitive=.{.value=primitive_types.f64_}}, Pin{.primitive=.{.value=primitive_types.f64_}}
        },
        .outputs = &.{ Pin{.primitive=.{.value=primitive_types.f64_}} }
    }),
    min: NodeDesc = basicNode(&.{
        .name = "max",
        .inputs = &.{
            Pin{.primitive=.{.value=primitive_types.f64_}}, Pin{.primitive=.{.value=primitive_types.f64_}}
        },
        .outputs = &.{ Pin{.primitive=.{.value=primitive_types.f64_}} }
    }),
    @"*": NodeDesc = basicNode(&.{
        .name = "*",
        .inputs = &.{
            Pin{.primitive=.{.value=primitive_types.f64_}}, Pin{.primitive=.{.value=primitive_types.f64_}}
        },
        .outputs = &.{ Pin{.primitive=.{.value=primitive_types.f64_}} }
    }),
    @"/": NodeDesc = basicNode(&.{
        .name = "/",
        .inputs = &.{
            Pin{.primitive=.{.value=primitive_types.f64_}}, Pin{.primitive=.{.value=primitive_types.f64_}}
        },
        .outputs = &.{ Pin{.primitive=.{.value=primitive_types.f64_}} }
    }),
    @"if": NodeDesc = basicNode(&.{
        .name = "if",
        .inputs = &.{ .{.primitive = .exec}, Pin{.primitive=.{.value=primitive_types.bool_}} },
        .outputs = &.{ .{.primitive = .exec}, .{.primitive = .exec} },
    }),
    // TODO: function...
    sequence: NodeDesc = basicNode(&.{
        .name = "sequence",
        .inputs = &.{ Pin{.primitive=.exec} },
        .outputs = &.{ Pin{.variadic=.exec} },
    }),

    @"set!": NodeDesc = basicNode(&.{
        .name = "set!",
        // FIXME: needs to be generic/per variable
        .inputs = &.{ Pin{.primitive=.exec}, Pin{.primitive=.{.value=primitive_types.f64_}} },
        .outputs = &.{ Pin{.primitive=.exec}, Pin{.primitive=.{.value=primitive_types.f64_}} },
    }),

    // "cast":
    @"switch": NodeDesc = basicNode(&.{
        .name = "switch",
        .inputs = &.{
            Pin{.primitive=.exec},
            Pin{.primitive=.{.value=primitive_types.f64_}},
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
        const capsule_component = VarNodes.init(failing_allocator, "capsule-component", types.scene_component)
            catch unreachable;
        const current_spawn_point = VarNodes.init(failing_allocator, "current-spawn-point", types.scene_component)
            catch unreachable;
        const drone_state = VarNodes.init(failing_allocator, "drone-state", types.scene_component)
            catch unreachable;
        const mesh = VarNodes.init(failing_allocator, "mesh", types.scene_component)
            catch unreachable;
        const over_time = VarNodes.init(failing_allocator, "over-time", types.scene_component)
            catch unreachable;
        const speed = VarNodes.init(failing_allocator, "speed", primitive_types.f32_)
            catch unreachable;

        custom_tick_call: NodeDesc = basicNode(&.{
            .name = "CustomTickCall",
            .inputs = &.{ Pin{.primitive=.{.value=types.actor}} },
            .outputs = &.{ Pin{.primitive=.{.value=primitive_types.vec3 }} },
        }),

        // FIXME: remove and just have an entry
        custom_tick_entry: NodeDesc = basicNode(&.{
            .name = "CustomTickEntry",
            .outputs = &.{ Pin{.primitive=.exec} },
        }),

        move_component_to: NodeDesc = basicNode(&.{
            .name = "Move Component To",
            .inputs = &.{
                // FIXME: what about pin names? :/
                Pin{.primitive=.exec},
                Pin{.primitive=.exec},
                Pin{.primitive=.exec},
                Pin{.primitive=.{.value=types.scene_component}},
                Pin{.primitive=.{.value=primitive_types.vec3}},
                Pin{.primitive=.{.value=primitive_types.vec4}},
                Pin{.primitive=.{.value=primitive_types.bool_}},
                Pin{.primitive=.{.value=primitive_types.bool_}},
                Pin{.primitive=.{.value=primitive_types.f32_}},
            },
            .outputs = &.{ Pin{.primitive=.exec}},
        }),

        break_hit_result: NodeDesc =
            makeBreakNodeForStruct(failing_allocator, types.hit_result)
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
            .name = "cast",
            .inputs = &. {
                exec,
                exec,
            },
            .outputs = &.{
                exec,
                exec,
                Pin{.primitive=.{.value=types.actor}},
            },
        }),

        do_once: NodeDesc = basicNode(&.{
            .name = "do-once",
            .inputs = &. {
                exec,
                exec, // reset
                Pin{.primitive=.{.value=primitive_types.bool_}}, // start closed
            },
            .outputs = &.{
                exec, // completed
            },
        }),

        fake_switch: NodeDesc = basicNode(&.{
            .name = "fake-switch",
            .inputs = &.{
                exec,
                Pin{.primitive=.{.value=primitive_types.f64_}},
            },
            .outputs = &.{
                exec, // move to player
                exec, // move up
                exec, // dead
            },
        }),

        get_actor_location: NodeDesc = basicNode(&.{
            .name = "get-actor-location",
            .inputs = &.{ Pin{.primitive=.{.value=types.actor}} },
            .outputs = &.{ Pin{.primitive=.{.value=primitive_types.vec3}} },
        }),

        get_actor_rotation: NodeDesc = basicNode(&.{
            .name = "get-actor-rotation",
            .inputs = &.{ Pin{.primitive=.{.value=types.actor}} },
            .outputs = &.{ Pin{.primitive=.{.value=primitive_types.vec4}} },
        }),

        get_socket_location: NodeDesc = basicNode(&.{
            .name = "get-socket-location",
            .inputs = &.{
                Pin{.primitive=.{.value=types.actor}},
                Pin{.primitive=.{.value=primitive_types.string}},
            },
            .outputs = &.{ Pin{.primitive=.{.value=primitive_types.vec3}} },
        }),

        fake_sequence_3: NodeDesc = basicNode(&.{
            .name = "fake-sequence-3",
            .inputs = &.{ exec },
            .outputs = &.{ exec, exec, exec },
        }),

        single_line_trace_by_channel: NodeDesc = basicNode(&.{
            .name = "single-line-trace-by-channel",
            .inputs = &.{
                exec,
                Pin{.primitive=.{.value=primitive_types.vec3}}, // start
                Pin{.primitive=.{.value=primitive_types.vec3}}, // end
                Pin{.primitive=.{.value=types.trace_channels}}, // channel
                Pin{.primitive=.{.value=primitive_types.bool_}}, // trace-complex
                Pin{.primitive=.{.value=types.actor_list}}, // actors-to-ignore
                Pin{.primitive=.{.value=types.draw_debug_types}}, // draw-debug-type (default 'none)
                Pin{.primitive=.{.value=primitive_types.bool_}}, // ignore-self (default false)
            },
            .outputs = &.{
                exec,
                Pin{.primitive=.{.value=types.hit_result}}, // out hit
                Pin{.primitive=.{.value=primitive_types.bool_}}, // did hit
            },
        }),

        vector_length: NodeDesc = basicNode(&.{
            .name = "vector-length",
            .inputs = &.{ Pin{.primitive=.{.value=primitive_types.vec3}} },
            .outputs = &.{ Pin{.primitive=.{.value=primitive_types.f64_}} },
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
        builtin_nodes.@"+".getOutputs()[0].primitive.value,
        primitive_types.f64_,
    );
    try std.testing.expect(temp_ue.nodes.custom_tick_entry.getOutputs()[0].primitive == .exec);
    try expectEqualTypes(
        temp_ue.nodes.break_hit_result.getOutputs()[2].primitive.value,
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

    pub fn makeNode(self: @This(), kind: []const u8, extra: anytype) ?GraphTypes(@TypeOf(extra)).Node {
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
