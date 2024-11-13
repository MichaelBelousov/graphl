//! builtin nodes

const std = @import("std");

const failing_allocator = std.testing.failing_allocator;

pub const FuncType = struct {
    param_names: []const []const u8 = &.{},
    param_types: []const Type = &.{},
    local_names: []const []const u8 = &.{},
    local_types: []const Type = &.{},
    result_names: []const []const u8 = &.{},
    result_types: []const Type = &.{},
};

pub const TypeInfo = struct {
    name: []const u8,
    field_names: []const []const u8 = &.{},
    // should structs allow constrained generic fields?
    field_types: []const Type = &.{},
    // FIXME: use a union
    func_type: ?FuncType = null,
    // the wasm primitive associated with this type, if it is a primitive
    wasm_primitive: ?[]const u8 = null,
};

pub const Type = *const TypeInfo;

pub const PrimitivePin = union(enum) {
    exec,
    value: Type,
};

pub const exec = Pin{ .name = "Exec", .kind = .{ .primitive = .exec } };

// FIXME: replace with or convert to sexp?
pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool: bool,
    null: void,
    symbol: []const u8,
};

pub const Pin = struct {
    name: []const u8,
    kind: union(enum) {
        primitive: PrimitivePin,
        variadic: PrimitivePin,
    },

    // TODO: rename to erase varidicness? idk
    pub fn asPrimitivePin(self: @This()) PrimitivePin {
        return switch (self.kind) {
            .primitive, .variadic => |v| v,
        };
    }

    pub fn isExec(self: @This()) bool {
        return self.kind == .primitive and self.kind.primitive == .exec;
    }
};

pub const NodeSpecialInfo = union(enum) {
    none: void,
    get: void,
    set: void,
};

pub const NodeDesc = struct {
    hidden: bool = false,

    // FIXME: horrible
    special: NodeSpecialInfo = .none,

    context: *const anyopaque,
    // TODO: do I really need pointers? The types are all going to be well defined aggregates,
    // and the nodes too
    // FIXME: read https://pithlessly.github.io/allocgate.html, the same logic as to why zig
    // stopped using @fieldParentPtr-based polymorphism applies here to, this is needlessly slow
    _getInputs: *const fn (*const NodeDesc) []const Pin,
    _getOutputs: *const fn (*const NodeDesc) []const Pin,
    /// name is relative to the env it is stored in
    _getName: *const fn (*const NodeDesc) []const u8,

    pub fn name(self: *const @This()) []const u8 {
        return self._getName(self);
    }

    pub fn getInputs(self: *const @This()) []const Pin {
        return self._getInputs(self);
    }

    pub fn getOutputs(self: *const @This()) []const Pin {
        return self._getOutputs(self);
    }

    pub fn maybeStaticOutputsLen(self: @This()) ?usize {
        const outputs = self.getOutputs();
        var is_static = true;
        for (outputs) |output| {
            if (output.kind == .variadic) {
                is_static = false;
                break;
            }
        }
        return if (is_static) outputs.len else null;
    }

    pub fn maybeStaticInputsLen(self: @This()) ?usize {
        const inputs = self.getInputs();
        var is_static = true;
        for (inputs) |input| {
            if (input.kind == .variadic) {
                is_static = false;
                break;
            }
        }
        return if (is_static) inputs.len else null;
    }

    const FlowType = enum {
        functionCall,
        pure,
        simpleBranch,
    };

    // FIXME: pre-calculate this at construction (or cache it?)
    pub fn isSimpleBranch(self: *const @This()) bool {
        const is_branch = self == &builtin_nodes.@"if";
        if (is_branch) {
            std.debug.assert(self.getOutputs().len == 2);
            std.debug.assert(self.getOutputs()[0].isExec());
            std.debug.assert(self.getOutputs()[1].isExec());
        }
        return is_branch;
    }

    pub fn isFunctionCall(self: @This()) bool {
        return !self.isSimpleBranch();
    }
};

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const GraphTypes = struct {
    pub const NodeId = u32;

    pub const Link = struct {
        target: NodeId,
        pin_index: u16,
        sub_index: u16 = 0,
    };

    pub const Input = union(enum) {
        link: ?Link,
        value: Value,
    };

    pub const Output = struct {
        link: Link,
    };

    const empty_inputs: []Input = &.{};
    const empty_outputs: []?Output = &.{};

    pub const Node = struct {
        id: NodeId,
        desc: *const NodeDesc,
        position: Point = .{},
        comment: ?[]const u8 = null,
        // FIMXE: how do we handle default inputs?
        inputs: []Input = empty_inputs,
        outputs: []?Output = empty_outputs,

        // FIXME: replace this, each node belongs to a well defined flow control archetype
        const OutExecIterator = struct {
            index: usize = 0,
            node: *const Node,

            pub fn next(self: *@This()) ??Link {
                while (self.index < self.node.outputs.len) : (self.index += 1) {
                    const output_desc = self.node.desc.getOutputs()[self.index];
                    const is_exec = output_desc == .primitive and output_desc.primitive == .exec;
                    if (!is_exec) continue;

                    const output = self.node.outputs[self.index];

                    self.index += 1;
                    return if (output) |o| o.link else null;
                }

                return null;
            }

            pub fn hasNext(self: @This()) bool {
                return self.index < self.node.outputs.len;
            }
        };

        fn iter_out_execs(self: @This()) OutExecIterator {
            return OutExecIterator{ .node = self };
        }

        pub fn initEmptyPins(
            a: std.mem.Allocator,
            args: struct {
                id: NodeId,
                desc: *const NodeDesc,
                comment: ?[]const u8 = null,
            },
        ) !@This() {
            const result = @This(){
                .id = args.id,
                .desc = args.desc,
                .comment = args.comment,
                // TODO: default to zero literal
                // TODO: handle variadic
                .inputs = if (args.desc.maybeStaticInputsLen()) |v| try a.alloc(Input, v) else @panic("non static inputs not supported"),
                .outputs = if (args.desc.maybeStaticOutputsLen()) |v| try a.alloc(?Output, v) else @panic("non static outputs not supported"),
            };

            for (result.inputs, args.desc.getInputs()) |*i, i_desc| {
                // if (i_desc.kind == .primitive and i_desc.kind.primitive == .value) {
                //     if (i_desc.kind.primitive.value == primitive_types.i32_ or i_desc.kind.primitive.value == primitive_types.u32_ or i_desc.kind.primitive.value == primitive_types.f32_ or i_desc.kind.primitive.value == primitive_types.i64_ or i_desc.kind.primitive.value == primitive_types.u64_ or i_desc.kind.primitive.value == primitive_types.f64_) {
                //         i.* = .{ .value = .{ .number = 0.0 } };
                //     } else {
                //         std.log.err("unknown type: '{s}'", .{i_desc.kind.primitive.value.name});
                //         // FIXME: non-numeric types should not default to 0, should be based on
                //         i.* = .{ .value = .{ .number = 0.0 } };
                //     }
                // }
                _ = i_desc;
                i.* = .{ .value = .{ .float = 0.0 } };
            }
            for (result.outputs) |*o| o.* = null;

            return result;
        }

        pub fn deinit(self: @This(), a: std.mem.Allocator) void {
            if (self.inputs.ptr != empty_inputs.ptr)
                a.free(self.inputs);
            if (self.outputs.ptr != empty_outputs.ptr)
                a.free(self.outputs);
        }
    };
};

// place holder during analysis
pub const empty_type: Type = &TypeInfo{ .name = "EMPTY_TYPE" };

pub const primitive_types = struct {
    // nums
    pub const i32_: Type = &TypeInfo{ .name = "i32", .wasm_primitive = "i32" };
    pub const i64_: Type = &TypeInfo{ .name = "i64", .wasm_primitive = "i64" };
    pub const u32_: Type = &TypeInfo{ .name = "u32", .wasm_primitive = "i32" };
    pub const u64_: Type = &TypeInfo{ .name = "u64", .wasm_primitive = "i64" };
    pub const f32_: Type = &TypeInfo{ .name = "f32", .wasm_primitive = "f32" };
    pub const f64_ = &TypeInfo{ .name = "f64", .wasm_primitive = "f64" };

    pub const byte: Type = &TypeInfo{ .name = "byte", .wasm_primitive = "u8" };
    pub const bool_: Type = &TypeInfo{ .name = "bool", .wasm_primitive = "u8" };
    pub const char_: Type = &TypeInfo{ .name = "char", .wasm_primitive = "u32" };
    pub const symbol: Type = &TypeInfo{ .name = "symbol", .wasm_primitive = "i32" };
    pub const @"void": Type = &TypeInfo{ .name = "void" };

    pub const string: Type = &TypeInfo{ .name = "string" };

    // FIXME: replace when we think out the macro system
    pub const code: Type = &TypeInfo{ .name = "code" };

    // pub const vec3: Type = &TypeInfo{
    //     .name = "vec3",
    //     .field_names = &.{ "x", "y", "z" },
    //     .field_types = &.{ f64_, f64_, f64_ },
    // };
    // pub const vec4: Type = &TypeInfo{
    //     .name = "vec4",
    //     .field_names = &.{ "x", "y", "z", "w" },
    //     .field_types = &.{ f64_, f64_, f64_, f64_ },
    // };

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
};

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

pub const BasicNodeDesc = struct {
    name: []const u8,
    hidden: bool = false,
    special: NodeSpecialInfo = .none,
    inputs: []const Pin = &.{},
    outputs: []const Pin = &.{},
};

/// caller owns memory!
pub fn basicNode(in_desc: *const BasicNodeDesc) NodeDesc {
    const BasicNodeImpl = struct {
        const Self = @This();

        pub fn getInputs(node: *const NodeDesc) []const Pin {
            const desc: *const BasicNodeDesc = @alignCast(@ptrCast(node.context));
            return desc.inputs;
        }

        pub fn getOutputs(node: *const NodeDesc) []const Pin {
            const desc: *const BasicNodeDesc = @alignCast(@ptrCast(node.context));
            return desc.outputs;
        }

        pub fn getName(node: *const NodeDesc) []const u8 {
            const desc: *const BasicNodeDesc = @alignCast(@ptrCast(node.context));
            return desc.name;
        }
    };

    return NodeDesc{
        .context = @ptrCast(in_desc),
        .hidden = in_desc.hidden,
        .special = in_desc.special,
        ._getInputs = BasicNodeImpl.getInputs,
        ._getOutputs = BasicNodeImpl.getOutputs,
        ._getName = BasicNodeImpl.getName,
    };
}

pub const BasicMutNodeDesc = struct {
    name: []const u8,
    hidden: bool = false,
    special: NodeSpecialInfo = .none,
    inputs: []Pin = &.{},
    outputs: []Pin = &.{},
};

pub fn basicMutableNode(in_desc: *const BasicMutNodeDesc) NodeDesc {
    const BasicMutNodeImpl = struct {
        const Self = @This();

        pub fn getInputs(node: *const NodeDesc) []const Pin {
            const desc: *const BasicMutNodeDesc = @alignCast(@ptrCast(node.context));
            return desc.inputs;
        }

        pub fn getOutputs(node: *const NodeDesc) []const Pin {
            const desc: *const BasicMutNodeDesc = @alignCast(@ptrCast(node.context));
            return desc.outputs;
        }

        pub fn getName(node: *const NodeDesc) []const u8 {
            const desc: *const BasicMutNodeDesc = @alignCast(@ptrCast(node.context));
            return desc.name;
        }
    };

    return NodeDesc{
        .context = @ptrCast(in_desc),
        .hidden = in_desc.hidden,
        .special = in_desc.special,
        ._getInputs = BasicMutNodeImpl.getInputs,
        ._getOutputs = BasicMutNodeImpl.getOutputs,
        ._getName = BasicMutNodeImpl.getName,
    };
}

pub const VarNodes = struct {
    get: NodeDesc,
    set: NodeDesc,

    fn init(alloc: std.mem.Allocator, var_name: []const u8, var_type: Type) !VarNodes {
        // FIXME: test and plug non-comptime alloc leaks
        comptime var getter_outputs_slot: [if (@inComptime()) 1 else 0]Pin = undefined;
        const _getter_outputs = if (@inComptime()) &getter_outputs_slot else try alloc.alloc(Pin, 1);
        _getter_outputs[0] = Pin{ .name = "value", .kind = .{ .primitive = .{ .value = var_type } } };
        const getter_outputs_slot_sealed = getter_outputs_slot;
        const getter_outputs = if (@inComptime()) &getter_outputs_slot_sealed else _getter_outputs;

        const getter_name: []const u8 = if (@inComptime())
            std.fmt.comptimePrint("#GET#{s}", .{var_name})
        else
            try std.fmt.allocPrint(alloc, "#GET#{s}", .{var_name});

        // FIXME: is there a better way to do this?
        comptime var setter_inputs_slot: [if (@inComptime()) 2 else 0]Pin = undefined;
        const _setter_inputs = if (@inComptime()) &setter_inputs_slot else try alloc.alloc(Pin, 2);
        _setter_inputs[0] = Pin{ .name = "initiate", .kind = .{ .primitive = .exec } };
        _setter_inputs[1] = Pin{ .name = "new value", .kind = .{ .primitive = .{ .value = var_type } } };
        const setter_inputs_slot_sealed = setter_inputs_slot;
        const setter_inputs = if (@inComptime()) &setter_inputs_slot_sealed else _setter_inputs;

        comptime var setter_outputs_slot: [if (@inComptime()) 2 else 0]Pin = undefined;
        const _setter_outputs = if (@inComptime()) &setter_outputs_slot else try alloc.alloc(Pin, 2);
        _setter_outputs[0] = Pin{ .name = "continue", .kind = .{ .primitive = .exec } };
        _setter_outputs[1] = Pin{ .name = "value", .kind = .{ .primitive = .{ .value = var_type } } };
        const setter_outputs_slot_sealed = setter_outputs_slot;
        const setter_outputs = if (@inComptime()) &setter_outputs_slot_sealed else _setter_outputs;

        const setter_name: []const u8 =
            if (@inComptime())
            std.fmt.comptimePrint("#SET#{s}", .{var_name})
        else
            try std.fmt.allocPrint(alloc, "#SET#{s}", .{var_name});

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

    const out_pins = if (@inComptime()) &out_pins_slot else try alloc.alloc(Pin, in_struct_type.field_types.len);

    for (in_struct_type.field_types, out_pins) |field_type, *out_pin| {
        out_pin.* = Pin{ .name = "FIXME", .kind = .{ .primitive = .{ .value = field_type } } };
    }

    const done_pins_slot = out_pins_slot;

    const done_out_pins = if (@inComptime()) &done_pins_slot else out_pins;

    const name = if (@inComptime())
        std.fmt.comptimePrint("break_{s}", .{in_struct_type.name})
    else
        std.fmt.allocPrint(alloc, "break_{s}", .{in_struct_type.name});

    const context: *const BreakNodeContext =
        if (@inComptime()) &BreakNodeContext{
        .struct_type = in_struct_type,
        .out_pins = done_out_pins,
    } else try alloc.create(BreakNodeContext{
        .struct_type = in_struct_type,
        .out_pins = out_pins,
    });

    const NodeImpl = struct {
        const Self = @This();

        pub fn getInputs(node: NodeDesc) []const Pin {
            const ctx: *const BreakNodeContext = @ptrCast(node.context);
            return &.{
                Pin{ .name = "struct", .kind = .{ .primitive = .{ .value = ctx.struct_type } } },
            };
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

pub const builtin_nodes = struct {
    // FIXME: replace with real macro system that isn't JSON hack
    pub const json_quote: NodeDesc = basicNode(&.{
        .name = "quote",
        .inputs = &.{
            Pin{ .name = "code", .kind = .{ .primitive = .{ .value = primitive_types.code } } },
        },
        .outputs = &.{
            Pin{ .name = "data", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
    });

    pub const @"+": NodeDesc = basicNode(&.{
        .name = "+",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
    });
    pub const @"-": NodeDesc = basicNode(&.{
        .name = "-",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
    });
    pub const max: NodeDesc = basicNode(&.{
        .name = "max",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
    });
    pub const min: NodeDesc = basicNode(&.{
        .name = "min",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
    });
    pub const @"*": NodeDesc = basicNode(&.{
        .name = "*",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
    });
    pub const @"/": NodeDesc = basicNode(&.{
        .name = "/",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
    });
    pub const @">=": NodeDesc = basicNode(&.{
        .name = ">=",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
    });
    pub const @"<=": NodeDesc = basicNode(&.{
        .name = "<=",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
    });
    pub const @"<": NodeDesc = basicNode(&.{
        .name = "<",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
    });
    pub const @">": NodeDesc = basicNode(&.{
        .name = ">",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
    });
    pub const @"==": NodeDesc = basicNode(&.{
        .name = "==",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
    });
    pub const @"!=": NodeDesc = basicNode(&.{
        .name = "!=",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
    });

    pub const not: NodeDesc = basicNode(&.{
        .name = "not",
        .inputs = &.{
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
    });

    pub const @"and": NodeDesc = basicNode(&.{
        .name = "and",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
    });

    pub const @"or": NodeDesc = basicNode(&.{
        .name = "or",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
    });

    pub const @"if": NodeDesc = basicNode(&.{
        .name = "if",
        .inputs = &.{
            Pin{ .name = "run", .kind = .{ .primitive = .exec } },
            Pin{ .name = "condition", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .outputs = &.{
            Pin{ .name = "then", .kind = .{ .primitive = .exec } },
            Pin{ .name = "otherwise", .kind = .{ .primitive = .exec } },
        },
    });
    // TODO: function...
    // pub const sequence: NodeDesc = basicNode(&.{
    //     .name = "sequence",
    //     .inputs = &.{
    //         Pin{ .name = "", .kind = .{ .primitive = .exec } },
    //     },
    //     .outputs = &.{
    //         Pin{ .name = "then", .kind = .{ .variadic = .exec } },
    //     },
    // });

    pub const @"set!": NodeDesc = basicNode(&.{
        .name = "set!",
        // FIXME: needs to be generic/per variable
        .inputs = &.{
            Pin{ .name = "run", .kind = .{ .primitive = .exec } },
            Pin{ .name = "variable", .kind = .{ .primitive = .{ .value = primitive_types.symbol } } },
            Pin{ .name = "new value", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "next", .kind = .{ .primitive = .exec } },
            Pin{ .name = "value", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
    });

    pub const func_start: NodeDesc = basicNode(&.{
        .name = "start",
        .hidden = true,
        .outputs = &.{
            Pin{ .name = "start", .kind = .{ .primitive = .exec } },
        },
    });

    // "cast":
    // pub const @"switch": NodeDesc = basicNode(&.{
    //     .name = "switch",
    //     .inputs = &.{
    //         Pin{ .name = "", .kind = .{ .primitive = .exec } },
    //         Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.f64_ } } },
    //     },
    //     .outputs = &.{
    //         Pin{ .name = "", .kind = .{ .variadic = .exec } },
    //     },
    // });
};

pub const temp_ue = struct {
    pub const types = struct {
        // TODO: impl enums
        // pub const physical_material: Type = &TypeInfo{ .name = "physical_material" };
        // pub const actor: Type = &TypeInfo{ .name = "actor" };
        // pub const scene_component: Type = &TypeInfo{ .name = "SceneComponent" };

        // // FIXME: use list(actor)
        // pub const actor_list: Type = &TypeInfo{ .name = "list(actor)" };
        // pub const trace_channels: Type = &TypeInfo{ .name = "trace_channels" };
        // pub const draw_debug_types: Type = &TypeInfo{ .name = "draw_debug_types" };
        // pub const hit_result: Type = &TypeInfo{
        //     .name = "hit_result",
        //     .field_names = &[_][]const u8{
        //         "location",
        //         "normal",
        //         "impact point",
        //         "impact normal",
        //         "physical material",
        //         "hit actor",
        //         "hit component",
        //         "hit bone name",
        //     },
        //     .field_types = &.{
        //         primitive_types.vec3,
        //         primitive_types.vec3,
        //         primitive_types.vec3,
        //         primitive_types.vec3,
        //         physical_material,
        //         actor,
        //         scene_component,
        //         primitive_types.string,
        //     },
        // };
    };

    pub const nodes = struct {
        // TODO: replace with live vars
        // const capsule_component = VarNodes.init(
        //     failing_allocator,
        //     "capsule-component",
        //     types.scene_component,
        // ) catch unreachable;
        // const current_spawn_point = VarNodes.init(failing_allocator, "current-spawn-point", types.scene_component) catch unreachable;
        // const drone_state = VarNodes.init(failing_allocator, "drone-state", types.scene_component) catch unreachable;
        // const mesh = VarNodes.init(failing_allocator, "mesh", types.scene_component) catch unreachable;
        // const over_time = VarNodes.init(failing_allocator, "over-time", types.scene_component) catch unreachable;
        // const speed = VarNodes.init(failing_allocator, "speed", primitive_types.f32_) catch unreachable;

        // pub const custom_tick_call: NodeDesc = basicNode(&.{
        //     .name = "CustomTickCall",
        //     .inputs = &.{
        //         Pin{ .name = "actor", .kind = .{ .primitive = .{ .value = types.actor } } },
        //     },
        //     .outputs = &.{
        //         Pin{ .name = "loc", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        //     },
        // });

        // pub const custom_tick_call: NodeDesc = basicNode(&.{
        //     .name = "CustomTickCall",
        //     .inputs = &.{
        //         Pin{ .name = "actor", .kind = .{ .primitive = .{ .value = types.actor } } },
        //     },
        //     .outputs = &.{
        //         Pin{ .name = "loc", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        //     },
        // });

        // pub const move_component_to: NodeDesc = basicNode(&.{
        //     .name = "Move Component To",
        //     .inputs = &.{
        //         Pin{ .name = "Move", .kind = .{ .primitive = .exec } },
        //         Pin{ .name = "Stop", .kind = .{ .primitive = .exec } },
        //         Pin{ .name = "Return", .kind = .{ .primitive = .exec } },
        //         Pin{ .name = "Component", .kind = .{ .primitive = .{ .value = types.scene_component } } },
        //         Pin{ .name = "TargetRelativeLocation", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        //         Pin{ .name = "TargetRelativeRotation", .kind = .{ .primitive = .{ .value = primitive_types.vec4 } } },
        //         Pin{ .name = "Ease Out", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        //         Pin{ .name = "Ease In", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        //         Pin{ .name = "Over Time", .kind = .{ .primitive = .{ .value = primitive_types.f32_ } } },
        //         Pin{ .name = "Force Shortest Rotation Time", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        //     },
        //     .outputs = &.{
        //         Pin{ .name = "Completed", .kind = .{ .primitive = .exec } },
        //     },
        // });

        // pub const break_hit_result: NodeDesc =
        //     makeBreakNodeForStruct(failing_allocator, types.hit_result) catch unreachable;

        // pub const get_capsule_component: NodeDesc = capsule_component.get;
        // pub const set_capsule_component: NodeDesc = capsule_component.set;

        // pub const get_current_spawn_point: NodeDesc = current_spawn_point.get;
        // pub const set_current_spawn_point: NodeDesc = current_spawn_point.set;

        // pub const get_drone_state: NodeDesc = drone_state.get;
        // pub const set_drone_state: NodeDesc = drone_state.set;

        // pub const get_mesh: NodeDesc = mesh.get;
        // pub const set_mesh: NodeDesc = mesh.set;

        // pub const get_over_time: NodeDesc = over_time.get;
        // pub const set_over_time: NodeDesc = over_time.set;

        // pub const get_speed: NodeDesc = speed.get;
        // pub const set_speed: NodeDesc = speed.set;

        // pub const cast: NodeDesc = basicNode(&.{
        //     .name = "cast",
        //     .inputs = &.{
        //         exec,
        //         exec,
        //     },
        //     .outputs = &.{
        //         exec,
        //         exec,
        //         Pin{ .name = "value", .kind = .{ .primitive = .{ .value = types.actor } } },
        //     },
        // });

        // pub const do_once: NodeDesc = basicNode(&.{
        //     .name = "do-once",
        //     .inputs = &.{
        //         exec,
        //         exec, // reset
        //         Pin{ .name = "start closed", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        //     },
        //     .outputs = &.{
        //         exec, // completed
        //     },
        // });

        // pub const fake_switch: NodeDesc = basicNode(&.{
        //     .name = "fake-switch",
        //     .inputs = &.{
        //         exec,
        //         Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.f64_ } } },
        //     },
        //     .outputs = &.{
        //         Pin{ .name = "move to player", .kind = .{ .primitive = .exec } },
        //         Pin{ .name = "move up", .kind = .{ .primitive = .exec } },
        //         Pin{ .name = "dead", .kind = .{ .primitive = .exec } },
        //     },
        // });

        // pub const this_actor_location: NodeDesc = basicNode(&.{
        //     .name = "#GET#actor-location",
        //     .inputs = &.{},
        //     .outputs = &.{
        //         Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        //     },
        // });

        // pub const get_location_of_actor: NodeDesc = basicNode(&.{
        //     .name = "get-actor-location",
        //     .inputs = &.{
        //         Pin{ .name = "", .kind = .{ .primitive = .{ .value = types.actor } } },
        //     },
        //     .outputs = &.{
        //         Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        //     },
        // });

        // pub const get_actor_rotation: NodeDesc = basicNode(&.{
        //     .name = "#GET#actor-rotation",
        //     .inputs = &.{
        //         Pin{ .name = "", .kind = .{ .primitive = .{ .value = types.actor } } },
        //     },
        //     .outputs = &.{
        //         Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.vec4 } } },
        //     },
        // });

        // pub const get_socket_location: NodeDesc = basicNode(&.{
        //     .name = "#GET#socket-location",
        //     .inputs = &.{
        //         Pin{ .name = "", .kind = .{ .primitive = .{ .value = types.actor } } },
        //         Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        //     },
        //     .outputs = &.{
        //         Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        //     },
        // });

        // pub const fake_sequence_3: NodeDesc = basicNode(&.{
        //     .name = "fake-sequence-3",
        //     .inputs = &.{exec},
        //     .outputs = &.{ exec, exec, exec },
        // });

        // pub const single_line_trace_by_channel: NodeDesc = basicNode(&.{
        //     .name = "single-line-trace-by-channel",
        //     .inputs = &.{
        //         exec,
        //         Pin{ .name = "start", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        //         Pin{ .name = "end", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        //         Pin{ .name = "channel", .kind = .{ .primitive = .{ .value = types.trace_channels } } },
        //         Pin{ .name = "trace-complex", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        //         Pin{ .name = "actors-to-ignore", .kind = .{ .primitive = .{ .value = types.actor_list } } },
        //         Pin{ .name = "draw-debug-type (default 'none)", .kind = .{ .primitive = .{ .value = types.draw_debug_types } } },
        //         Pin{ .name = "ignore-self (default false)", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        //     },
        //     .outputs = &.{
        //         exec,
        //         Pin{ .name = "out hit", .kind = .{ .primitive = .{ .value = types.hit_result } } },
        //         Pin{ .name = "did hit", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        //     },
        // });

        // pub const vector_length: NodeDesc = basicNode(&.{
        //     .name = "vector-length",
        //     .inputs = &.{
        //         Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        //     },
        //     .outputs = &.{
        //         Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.f64_ } } },
        //     },
        // });
    };
};

fn expectEqualTypes(actual: Type, expected: Type) !void {
    if (actual != expected) {
        // TODO: implement format for types
        std.debug.print("Expected '{s}'<{*}> but got '{s}'<{*}>\n", .{ actual.name, actual, expected.name, expected });
        return error.TestFail;
    }
}

test "node types" {
    try std.testing.expectEqual(
        builtin_nodes.@"+".getOutputs()[0].kind.primitive.value,
        primitive_types.i32_,
    );
    try std.testing.expect(builtin_nodes.func_start.getOutputs()[0].kind.primitive == .exec);
    //try expectEqualTypes(temp_ue.nodes.break_hit_result.getOutputs()[2].kind.primitive.value, primitive_types.vec3);
}

pub const Env = struct {
    types: std.StringHashMapUnmanaged(Type) = .{},
    // could be macro, function, operator
    nodes: std.StringHashMapUnmanaged(*const NodeDesc) = .{},

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.types.clearAndFree(alloc);
        self.nodes.clearAndFree(alloc);
        // FIXME: destroy all created slots
    }

    pub fn initDefault(alloc: std.mem.Allocator) !@This() {
        var env = @This(){};

        inline for (&.{ primitive_types, temp_ue.types }) |types| {
            //const types_decls = comptime std.meta.declList(types, TypeInfo);
            const types_decls = comptime std.meta.declarations(types);
            try env.types.ensureTotalCapacity(alloc, @intCast(types_decls.len));
            inline for (types_decls) |d| {
                const type_ = @field(types, d.name);
                try env.types.put(alloc, type_.name, type_);
            }
        }

        inline for (&.{ builtin_nodes, temp_ue.nodes }) |nodes| {
            // TODO: select by type so we can make public other types
            //const nodes_decls = std.meta.declList(nodes, NodeDesc);
            const nodes_decls = comptime std.meta.declarations(nodes);
            try env.nodes.ensureTotalCapacity(alloc, @intCast(nodes_decls.len));
            inline for (nodes_decls) |n| {
                const node = @field(nodes, n.name);
                try env.nodes.put(alloc, node.name(), &node);
            }
        }

        return env;
    }

    pub fn makeNode(self: *const @This(), a: std.mem.Allocator, id: GraphTypes.NodeId, kind: []const u8) !?GraphTypes.Node {
        return if (self.nodes.get(kind)) |desc|
            try GraphTypes.Node.initEmptyPins(a, .{ .id = id, .desc = desc })
        else
            null;
    }

    pub fn addType(self: *@This(), a: std.mem.Allocator, type_info: TypeInfo) !Type {
        // TODO: dupe the key, we need to own the key memory lifetime
        const result = try self.types.getOrPut(a, type_info.name);
        // FIXME: allow types to be overriden within scopes?
        if (result.found_existing) return error.EnvAlreadyExists;
        // FIXME: leak
        const slot = try a.create(TypeInfo);
        slot.* = type_info;
        result.value_ptr.* = slot;
        return slot;
    }

    pub fn addNode(self: *@This(), a: std.mem.Allocator, node_desc: NodeDesc) !*NodeDesc {
        // TODO: dupe the key, we need to own the key memory lifetime
        const result = try self.nodes.getOrPut(a, node_desc.name());
        // FIXME: allow types to be overriden within scopes?
        if (result.found_existing) return error.EnvAlreadyExists;
        // FIXME: leak
        const slot = try a.create(NodeDesc);
        slot.* = node_desc;
        result.value_ptr.* = slot;

        return slot;
    }
};

test "env" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.types.contains("u32"));
}
