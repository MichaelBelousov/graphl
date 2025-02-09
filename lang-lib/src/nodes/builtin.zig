//! builtin nodes

const std = @import("std");
const Sexp = @import("../sexp.zig").Sexp;

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
    wasm_type: ?[]const u8 = null,
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

pub const NodeDescKind = union(enum) {
    func: void,
    // TODO: rename to @"return"
    return_: void,
    entry: void,
    get: void,
    set: void,
};

pub const NodeDesc = struct {
    hidden: bool = false,

    kind: NodeDescKind = .func,

    tags: []const []const u8 = &.{},
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

pub const Binding = struct {
    name: []u8,
    type_: Type,
    comment: ?[]u8 = null,
    default: ?Sexp = null,
    // FIXME: gross, used currently for custom associated data
    extra: ?*anyopaque = null,
};

pub const GraphTypes = struct {
    pub const NodeId = u32;

    pub const Link = struct {
        target: NodeId,
        pin_index: u16,
        sub_index: u16 = 0,

        /// used when targets are invalidated
        pub fn isDeadOutput(self: *const Link) bool {
            return self.target == dead_outlink.target;
        }
    };

    pub const Input = union(enum) {
        link: Link,
        value: Value,
    };

    /// used to simplify deletion of links
    pub const dead_outlink = Link{
        .target = 0,
        .pin_index = 0,
        .sub_index = 0,
    };

    pub const Outputs = struct {
        /// N.B: might be a dead_outlink, since target=0 is invalid for an output
        /// (entry can't be targeted by an output)
        links: std.SegmentedList(Link, 2) = .{},
        dead_count: u32 = 0,

        pub fn first(self: *const Outputs) ?*const Link {
            var iter = self.links.constIterator(0);
            while (iter.next()) |link| {
                if (!link.isDeadOutput())
                    return link;
            }
            return null;
        }

        pub fn append(self: *Outputs, a: std.mem.Allocator, link: Link) std.mem.Allocator.Error!void {
            var iter = self.links.iterator(0);
            while (iter.next()) |curr| {
                if (curr.isDeadOutput()) {
                    curr.* = link;
                    return;
                }
            }
            return self.links.append(a, link);
        }

        // TODO: make faster
        pub fn len(self: *const Outputs) usize {
            return self.links.len - self.dead_count;
        }

        pub fn getExecOutput(self: *const Outputs) ?*const Link {
            std.debug.assert(self.links.len <= 1);
            return if (self.links.len == 1) self.links.uncheckedAt(0) else null;
        }

        pub fn setExecOutput(self: *Outputs, link: Link) void {
            std.debug.assert(self.links.len <= 1);
            self.links.len = 1;
            self.links.uncheckedAt(0).* = link;
        }

        // FIXME: remove in place of setExecOutput taking an output
        pub fn removeExecOutput(self: *Outputs) void {
            std.debug.assert(self.links.len <= 1);
            self.links.clearRetainingCapacity();
        }
    };

    const empty_inputs: []Input = &.{};
    const empty_outputs: []Outputs = &.{};

    pub const Node = struct {
        id: NodeId,
        position: Point = .{},
        label: ?[]const u8 = null,
        comment: ?[]const u8 = null,
        // FIMXE: how do we handle default inputs?
        inputs: []Input = empty_inputs,
        outputs: []Outputs = empty_outputs,

        // TODO: rename and remove function
        _desc: *const NodeDesc,

        pub fn desc(self: *const @This()) *const NodeDesc {
            return self._desc;
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
                ._desc = args.desc,
                .comment = args.comment,
                // TODO: default to zero literal
                // TODO: handle variadic
                .inputs = if (args.desc.maybeStaticInputsLen()) |v| try a.alloc(Input, v) else @panic("non static inputs not supported"),
                .outputs = if (args.desc.maybeStaticOutputsLen()) |v| try a.alloc(Outputs, v) else @panic("non static outputs not supported"),
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
            for (result.outputs) |*o| o.* = .{};

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
    pub const i32_: Type = &TypeInfo{ .name = "i32", .wasm_type = "i32" };
    pub const i64_: Type = &TypeInfo{ .name = "i64", .wasm_type = "i64" };
    pub const u32_: Type = &TypeInfo{ .name = "u32", .wasm_type = "i32" };
    pub const u64_: Type = &TypeInfo{ .name = "u64", .wasm_type = "i64" };
    pub const f32_: Type = &TypeInfo{ .name = "f32", .wasm_type = "f32" };
    pub const f64_ = &TypeInfo{ .name = "f64", .wasm_type = "f64" };

    pub const byte: Type = &TypeInfo{ .name = "byte", .wasm_type = "u8" };
    // FIXME: should I change this to u8?
    pub const bool_: Type = &TypeInfo{ .name = "bool", .wasm_type = "i32" };
    pub const char_: Type = &TypeInfo{ .name = "char", .wasm_type = "u32" };
    pub const symbol: Type = &TypeInfo{ .name = "symbol", .wasm_type = "i32" };
    pub const @"void": Type = &TypeInfo{ .name = "void" };

    // FIXME: this is basically a pointer, but should consider writing a comptime function
    // for converting from instrinsics type to wasm type
    pub const string: Type = &TypeInfo{ .name = "string", .wasm_type = "i32" };

    // FIXME: this is basically a pointer, but should consider writing a comptime function
    // for converting from instrinsics type to wasm type
    pub const vec3: Type = &TypeInfo{ .name = "vec3", .wasm_type = "i32" };

    pub const rgba: Type = &TypeInfo{ .name = "rgba", .wasm_type = "u32" };

    // FIXME: replace when we think out the macro system
    pub const code: Type = &TypeInfo{
        .name = "code",
        .wasm_type = "i32", // this is a stand in for "string"
    };

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
    // FIXME: remove in favor of nodes directly referencing whether they are a getter/setter
    kind: NodeDescKind = .func,
    inputs: []const Pin = &.{},
    outputs: []const Pin = &.{},
    tags: []const []const u8 = &.{},
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
        .kind = in_desc.kind,
        ._getInputs = BasicNodeImpl.getInputs,
        ._getOutputs = BasicNodeImpl.getOutputs,
        ._getName = BasicNodeImpl.getName,
    };
}

pub const BasicMutNodeDesc = struct {
    name: []const u8,
    hidden: bool = false,
    kind: NodeDescKind = .func,
    inputs: []Pin = &.{},
    outputs: []Pin = &.{},
    tags: []const []const u8 = &.{},
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
        .kind = in_desc.kind,
        ._getInputs = BasicMutNodeImpl.getInputs,
        ._getOutputs = BasicMutNodeImpl.getOutputs,
        ._getName = BasicMutNodeImpl.getName,
    };
}

pub const VarNodes = struct {
    get: NodeDesc,
    set: NodeDesc,

    fn init(
        alloc: std.mem.Allocator,
        var_name: []const u8,
        var_type: Type,
    ) !VarNodes {
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
            // TODO: this should output a sexp type
            Pin{ .name = "data", .kind = .{ .primitive = .{ .value = primitive_types.code } } },
        },
        .tags = &.{"json"},
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
        .tags = &.{"math"},
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
        .tags = &.{"math"},
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
        .tags = &.{"math"},
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
        .tags = &.{"math"},
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
        .tags = &.{"math"},
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
        .tags = &.{"math"},
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
        .tags = &.{"comparison"},
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
        .tags = &.{"comparison"},
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
        .tags = &.{"comparison"},
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
        .tags = &.{"comparison"},
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
        .tags = &.{"comparison"},
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
        .tags = &.{"comparison"},
    });

    pub const not: NodeDesc = basicNode(&.{
        .name = "not",
        .inputs = &.{
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .tags = &.{"boolean"},
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
        .tags = &.{"boolean"},
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
        .tags = &.{"boolean"},
    });

    pub const @"if": NodeDesc = basicNode(&.{
        .name = "if",
        .inputs = &.{
            Pin{ .name = "run", .kind = .{ .primitive = .exec } },
            Pin{ .name = "condition", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .outputs = &.{
            Pin{ .name = "then", .kind = .{ .primitive = .exec } },
            Pin{ .name = "else", .kind = .{ .primitive = .exec } },
        },
        .tags = &.{"control flow"},
    });

    pub const string_equal: NodeDesc = basicNode(&.{
        .name = "String-Equal",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .outputs = &.{
            Pin{ .name = "equal", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .tags = &.{"string"},
    });

    pub const string_concat: NodeDesc = basicNode(&.{
        .name = "Join",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .outputs = &.{
            Pin{ .name = "equal", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .tags = &.{"string"},
    });

    pub const make_vec3: NodeDesc = basicNode(&.{
        .name = "Make-Vec3",
        .inputs = &.{
            Pin{ .name = "X", .kind = .{ .primitive = .{ .value = primitive_types.f64_ } } },
            Pin{ .name = "Y", .kind = .{ .primitive = .{ .value = primitive_types.f64_ } } },
            Pin{ .name = "Z", .kind = .{ .primitive = .{ .value = primitive_types.f64_ } } },
        },
        .outputs = &.{
            Pin{ .name = "Vec3", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        },
        .tags = &.{"vector"},
    });

    // FIXME: replace with rgba "break" struct
    pub const vec3_x: NodeDesc = basicNode(&.{
        .name = "Vec3->X",
        .inputs = &.{
            Pin{ .name = "Vec3", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        },
        .outputs = &.{
            Pin{ .name = "X", .kind = .{ .primitive = .{ .value = primitive_types.f64_ } } },
        },
        .tags = &.{"vector"},
    });
    pub const vec3_y: NodeDesc = basicNode(&.{
        .name = "Vec3->Y",
        .inputs = &.{
            Pin{ .name = "Vec3", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        },
        .outputs = &.{
            Pin{ .name = "Y", .kind = .{ .primitive = .{ .value = primitive_types.f64_ } } },
        },
        .tags = &.{"vector"},
    });
    pub const vec3_z: NodeDesc = basicNode(&.{
        .name = "Vec3->Z",
        .inputs = &.{
            Pin{ .name = "Vec3", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
        },
        .outputs = &.{
            Pin{ .name = "Z", .kind = .{ .primitive = .{ .value = primitive_types.f64_ } } },
        },
        .tags = &.{"vector"},
    });

    // FIXME: replace with rgba "break" struct
    pub const rgba_r: NodeDesc = basicNode(&.{
        .name = "RGBA->R",
        .inputs = &.{
            Pin{ .name = "RGBA", .kind = .{ .primitive = .{ .value = primitive_types.rgba } } },
        },
        .outputs = &.{
            Pin{ .name = "R", .kind = .{ .primitive = .{ .value = primitive_types.byte } } },
        },
        .tags = &.{"color"},
    });
    pub const rgba_g: NodeDesc = basicNode(&.{
        .name = "RGBA->G",
        .inputs = &.{
            Pin{ .name = "RGBA", .kind = .{ .primitive = .{ .value = primitive_types.rgba } } },
        },
        .outputs = &.{
            Pin{ .name = "G", .kind = .{ .primitive = .{ .value = primitive_types.byte } } },
        },
        .tags = &.{"color"},
    });
    pub const rgba_b: NodeDesc = basicNode(&.{
        .name = "RGBA->B",
        .inputs = &.{
            Pin{ .name = "RGBA", .kind = .{ .primitive = .{ .value = primitive_types.rgba } } },
        },
        .outputs = &.{
            Pin{ .name = "B", .kind = .{ .primitive = .{ .value = primitive_types.byte } } },
        },
        .tags = &.{"color"},
    });
    pub const rgba_a: NodeDesc = basicNode(&.{
        .name = "RGBA->A",
        .inputs = &.{
            Pin{ .name = "RGBA", .kind = .{ .primitive = .{ .value = primitive_types.rgba } } },
        },
        .outputs = &.{
            Pin{ .name = "A", .kind = .{ .primitive = .{ .value = primitive_types.byte } } },
        },
        .tags = &.{"color"},
    });

    pub const make_rgba: NodeDesc = basicNode(&.{
        .name = "Make-RGBA",
        .inputs = &.{
            // FIXME: use bytes, ignoring for now
            Pin{ .name = "R", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "G", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "B", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "A", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "RGBA", .kind = .{ .primitive = .{ .value = primitive_types.rgba } } },
        },
        .tags = &.{"color"},
    });

    // FIXME: TEMP FOR DEMO
    pub const like: NodeDesc = basicNode(&.{
        .name = "like",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .outputs = &.{
            Pin{ .name = "equal", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .tags = &.{"sql"},
    });

    pub const string_indexof: NodeDesc = basicNode(&.{
        .name = "Index Of",
        .inputs = &.{
            Pin{ .name = "string", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
            Pin{ .name = "char", .kind = .{ .primitive = .{ .value = primitive_types.char_ } } },
        },
        .outputs = &.{
            Pin{ .name = "index", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .tags = &.{"string"},
    });

    pub const string_length: NodeDesc = basicNode(&.{
        .name = "Length",
        .inputs = &.{
            Pin{ .name = "string", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .outputs = &.{
            Pin{ .name = "length", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .tags = &.{"string"},
    });

    pub const make_string: NodeDesc = basicNode(&.{
        .name = "Make String",
        .inputs = &.{
            Pin{ .name = "string", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .outputs = &.{
            Pin{ .name = "string", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .tags = &.{"string"},
    });

    pub const make_symbol: NodeDesc = basicNode(&.{
        .name = "Make Symbol",
        .inputs = &.{
            Pin{ .name = "string", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .outputs = &.{
            Pin{ .name = "symbol", .kind = .{ .primitive = .{ .value = primitive_types.symbol } } },
        },
        .tags = &.{"symbol"},
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
        .tags = &.{"set"},
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

test "node types" {
    try std.testing.expectEqual(
        builtin_nodes.@"+".getOutputs()[0].kind.primitive.value,
        primitive_types.i32_,
    );
    try std.testing.expect(builtin_nodes.func_start.getOutputs()[0].kind.primitive == .exec);
    //try expectEqualTypes(temp_ue.nodes.break_hit_result.getOutputs()[2].kind.primitive.value, primitive_types.vec3);
}

pub const Env = struct {
    parentEnv: ?*const Env = null,

    _types: std.StringHashMapUnmanaged(Type) = .{},
    // could be macro, function, operator
    _nodes: std.StringHashMapUnmanaged(*const NodeDesc) = .{},
    // TODO: use this!
    _nodes_by_tag: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(*const NodeDesc)) = .{},

    created_types: std.SinglyLinkedList(TypeInfo) = .{},
    created_nodes: std.SinglyLinkedList(NodeDesc) = .{},

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self._types.clearAndFree(alloc);
        self._nodes.clearAndFree(alloc);
        while (self.created_nodes.popFirst()) |popped| alloc.destroy(popped);
        while (self.created_types.popFirst()) |popped| alloc.destroy(popped);
        // FIXME: destroy all created slots
    }

    pub fn spawn(self: *const @This()) @This() {
        return @This(){
            .parentEnv = self,
        };
    }

    pub fn initDefault(alloc: std.mem.Allocator) !@This() {
        var env = @This(){};

        inline for (&.{ primitive_types, temp_ue.types }) |types| {
            //const types_decls = comptime std.meta.declList(types, TypeInfo);
            const types_decls = comptime std.meta.declarations(types);
            try env._types.ensureTotalCapacity(alloc, @intCast(types_decls.len));
            inline for (types_decls) |d| {
                const type_ = @field(types, d.name);
                try env._types.put(alloc, type_.name, type_);
            }
        }

        inline for (&.{ builtin_nodes, temp_ue.nodes }) |nodes| {
            // TODO: select by type so we can make public other types
            //const nodes_decls = std.meta.declList(nodes, NodeDesc);
            const nodes_decls = comptime std.meta.declarations(nodes);
            try env._nodes.ensureTotalCapacity(alloc, @intCast(nodes_decls.len));
            inline for (nodes_decls) |n| {
                const node = @field(nodes, n.name);
                try env._nodes.put(alloc, node.name(), &@field(nodes, n.name));
            }
        }

        return env;
    }

    pub fn spawnNodeOfKind(self: *const @This(), a: std.mem.Allocator, id: GraphTypes.NodeId, kind: []const u8) !?GraphTypes.Node {
        return if (self.getNode(kind)) |desc|
            try GraphTypes.Node.initEmptyPins(a, .{ .id = id, .desc = desc })
        else
            null;
    }

    pub const TypeIterator = struct {
        parentEnv: ?*const Env,
        iter: std.StringHashMapUnmanaged(Type).ValueIterator,

        pub fn next(self: *@This()) ?Type {
            var val = self.iter.next();
            while (val == null and self.parentEnv != null) {
                self.iter = self.parentEnv.?._types.valueIterator();
                self.parentEnv = self.parentEnv.?.parentEnv;
                val = self.iter.next();
            }
            return if (val) |v| v.* else null;
        }
    };

    pub fn typeIterator(self: *@This()) TypeIterator {
        return TypeIterator{
            .parentEnv = self.parentEnv,
            .iter = self._types.valueIterator(),
        };
    }

    pub fn typeCount(self: *const @This()) usize {
        var result: usize = 0;
        var maybe_cursor: ?*const @This() = self;
        while (maybe_cursor) |cursor| : (maybe_cursor = cursor.parentEnv) {
            result += cursor._types.count();
        }
        return result;
    }

    pub const NodeIterator = struct {
        parentEnv: ?*const Env,
        iter: std.StringHashMapUnmanaged(*const NodeDesc).ValueIterator,

        pub fn next(self: *@This()) ?*const NodeDesc {
            var val = self.iter.next();
            while (val == null and self.parentEnv != null) {
                self.iter = self.parentEnv.?._nodes.valueIterator();
                self.parentEnv = self.parentEnv.?.parentEnv;
                val = self.iter.next();
            }
            return if (val) |v| v.* else null;
        }
    };

    pub fn nodeIterator(self: *@This()) NodeIterator {
        return NodeIterator{
            .parentEnv = self.parentEnv,
            .iter = self._nodes.valueIterator(),
        };
    }

    // FIXME: use interning for name!
    pub fn getType(self: *const @This(), name: []const u8) ?Type {
        return self._types.get(name) orelse if (self.parentEnv) |parent| parent.getType(name) else null;
    }

    // FIXME: use interning for name!
    pub fn getNode(self: *const @This(), name: []const u8) ?*const NodeDesc {
        return self._nodes.get(name) orelse if (self.parentEnv) |parent| parent.getNode(name) else null;
    }

    pub fn addType(self: *@This(), a: std.mem.Allocator, type_info: TypeInfo) !Type {
        // TODO: dupe the key, we need to own the key memory lifetime
        const result = try self._types.getOrPut(a, type_info.name);
        // FIXME: allow types to be overriden within scopes?
        if (result.found_existing) return error.EnvAlreadyExists;
        const slot = try a.create(std.SinglyLinkedList(TypeInfo).Node);
        slot.* = .{
            .data = type_info,
            .next = null,
        };
        self.created_types.prepend(slot);
        result.value_ptr.* = &slot.data;
        return &slot.data;
    }

    pub fn addNode(self: *@This(), a: std.mem.Allocator, node_desc: NodeDesc) !*NodeDesc {
        // TODO: dupe the key, we need to own the key memory lifetime
        const result = try self._nodes.getOrPut(a, node_desc.name());
        // FIXME: allow types to be overriden within scopes?
        if (result.found_existing) return error.EnvAlreadyExists;
        const slot = try a.create(std.SinglyLinkedList(NodeDesc).Node);
        slot.* = .{
            .data = node_desc,
            .next = null,
        };
        self.created_nodes.prepend(slot);
        result.value_ptr.* = &slot.data;
        return &slot.data;
    }
};

test "env" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env._types.contains("u32"));
}
