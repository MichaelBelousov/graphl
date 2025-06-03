//! builtin nodes

const std = @import("std");
const Sexp = @import("../sexp.zig").Sexp;
const Vec3 = @import("../intrinsics/vec3/Vec3.zig");
const binaryen = @import("binaryen");

const failing_allocator = std.testing.failing_allocator;

pub const FuncType = struct {
    param_names: []const [:0]const u8 = &.{},
    param_types: []const Type = &.{},
    local_names: []const [:0]const u8 = &.{},
    local_types: []const Type = &.{},
    result_names: []const [:0]const u8 = &.{},
    result_types: []const Type = &.{},
};

// FIXME: recursive types not supported
pub const StructType = struct {
    field_names: []const [:0]const u8 = &.{},
    // should structs allow constrained generic fields?
    field_types: []const Type = &.{},
    // I feel like 32-bits is too many
    field_offsets: []const u32 = &.{},
    // FIXME: add field defaults

    // FIXME: why have a size when the outer Type value will have one?
    size: u32,

    // FIXME: this is binaryen specific!
    /// total amount of array fields if you recursively descend through all fields
    flat_array_count: u16,
    /// total amount of primitive fields if you recursively descend through all fields
    flat_primitive_slot_count: u16,

    pub fn initFromTypeList(alloc: std.mem.Allocator, arg: struct {
        field_names: []const [:0]const u8 = &.{},
        field_types: []const Type = &.{},
    }) !@This() {
        const field_offsets = try alloc.alloc(u32, arg.field_names.len);
        var offset: u32 = 0;
        var flat_primitive_slot_count: u16 = 0;
        var flat_array_count: u16 = 0;

        for (arg.field_types, field_offsets) |field_type, *field_offset| {
            field_offset.* = offset;
            offset += field_type.size;
            switch (field_type.subtype) {
                .@"struct" => |substruct_type| {
                    flat_primitive_slot_count += substruct_type.flat_primitive_slot_count;
                    flat_array_count += substruct_type.flat_array_count;
                },
                .primitive => {
                    if (field_type == primitive_types.string) {
                        flat_array_count += 1;
                    } else {
                        flat_primitive_slot_count += 1;
                    }
                },
                else => @panic("unimplemented"),
            }
        }
        const total_size = offset;
        return @This(){
            .field_names = arg.field_names,
            .field_types = arg.field_types,
            .field_offsets = field_offsets,
            .size = total_size,
            .flat_primitive_slot_count = flat_primitive_slot_count,
            .flat_array_count = flat_array_count,
        };
    }
};

pub const ArrayType = struct {
    type: Type,
    fixed_size: ?u32,
};

// FIXME: causes zigar bug?
// TODO: consider adding (payload) unions?
// pub const EnumType = struct {
//     variants: std.ArrayListUnmanaged(Sexp),
// };

// could use a u32 index into a type store
pub const TypeInfo = struct {
    name: [:0]const u8,
    subtype: union(enum) {
        primitive: void,
        // TODO: figure out how this differs from "Node"
        func: *const NodeDesc,
        @"struct": StructType,
        array: ArrayType,
        //@"enum": EnumType,
    } = .primitive,
    /// size in bytes of the type
    size: u32,

    pub const SubfieldInfo = struct {
        name: [:0]const u8,
        type: Type,
        offset: u32,
    };

    // NOTE: I am probably getting ahead of myself implementing recursive fields
    pub fn recursiveSubfieldIterator(self: *const @This(), a: std.mem.Allocator) SubfieldIter {
        std.debug.assert(self.subtype == .@"struct");
        var result = SubfieldIter{
            .stack = @FieldType(SubfieldIter, "stack"){},
            ._alloc = a,
        };
        // FIXME: why doesn't SegmentedList support appendAssumeCapacity?
        result.stack.len = 1;
        result.stack.uncheckedAt(0).* = .{
            .type = self,
            .depth = std.math.maxInt(@FieldType(SubfieldIter.StackEntry, "depth")),
        };
        result.moveToNextPrimitive();
        return result;
    }

    // FIXME: store visited type list to detect loops
    // FIXME: add tests for this
    pub const SubfieldIter = struct {
        _alloc: std.mem.Allocator,
        _total_offset: u32 = 0,
        // TODO: support deeper structs
        stack: std.SegmentedList(StackEntry, 8),

        const StackEntry = struct { type: Type, depth: u16 };

        pub fn next(self: *@This()) ?SubfieldInfo {
            if (self.stack.count() == 0) {
                return null;
            }

            const top = self.stack.uncheckedAt(self.stack.count() - 1);
            const result = SubfieldInfo{
                .name = top.type.subtype.@"struct".field_names[top.depth],
                .type = top.type.subtype.@"struct".field_types[top.depth],
                .offset = self._total_offset,
            };
            // FIXME: hack
            self._total_offset += if (result.type == primitive_types.string) 0 else result.type.size;
            self.moveToNextPrimitive();
            return result;
        }

        fn moveToNextPrimitive(self: *@This()) void {
            std.debug.assert(self.stack.count() > 0);
            const start_top: *StackEntry = self.stack.uncheckedAt(self.stack.count() - 1);
            start_top.depth +%= 1; // FIXME this could bite me, infinite loop if struct > max(u16)

            while (self.stack.count() > 0) {
                const top: *StackEntry = self.stack.uncheckedAt(self.stack.count() - 1);
                if (top.depth >= top.type.subtype.@"struct".field_types.len) {
                    _ = self.stack.pop() orelse unreachable;
                    continue;
                    // FIXME generalize this or move this code to wasm compiler
                }

                const curr_field_type = top.type.subtype.@"struct".field_types[top.depth];
                if (curr_field_type.subtype == .primitive) {
                    return;
                } else if (curr_field_type.subtype == .@"struct") {
                    self.stack.append(self._alloc, .{ .type = curr_field_type, .depth = 0 }) catch unreachable;
                } else {
                    top.depth += 1;
                }
            }
        }
    };
};

pub const Type = *const TypeInfo;

pub const PrimitivePin = union(enum) {
    exec,
    value: Type,
};

pub const exec = Pin{ .name = "Exec", .kind = .{ .primitive = .exec } };

// this is basically a pared-down version of Sexp
pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool: bool,
    // FIXME: rename to "void" to match sexp
    null: void,
    symbol: []const u8,
};

// TODO: get these out of the default env maybe?
pub const jsonStrToGraphlType: std.StaticStringMap(Type) = _: {
    break :_ std.StaticStringMap(Type).initComptime(.{
        .{ "u32", primitive_types.u32_ },
        .{ "u64", primitive_types.u64_ },
        .{ "i32", primitive_types.i32_ },
        .{ "i64", primitive_types.i64_ },
        .{ "f32", primitive_types.f32_ },
        .{ "f64", primitive_types.f64_ },
        .{ "string", primitive_types.string },
        .{ "code", primitive_types.code },
        .{ "bool", primitive_types.bool_ },
        .{ "rgba", primitive_types.rgba },
        .{ "vec3", nonprimitive_types.vec3 },
    });
};


pub const Pin = struct {
    name: [:0]const u8 = "",
    description: ?[:0]const u8 = null,
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

    const JsonType = struct {
        name: [:0]const u8,
        description: ?[:0]const u8 = null,
        type: []const u8,
    };

    pub fn jsonStringify(self: *const @This(), jws: anytype) std.mem.Allocator.Error!void {
        try jws.write(.{
            .name = self.name,
            .description = self.description,
            // FIXME: handle non-primitives
            .type = switch (self.kind.primitive) {
                .exec => "exec",
                .value => |v| v.name,
            },
        });
    }

    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const raw_parsed = try std.json.innerParse(JsonType, a, source, options);

        return @This(){
            .name = raw_parsed.name,
            .description = raw_parsed.description,
            .kind = if (std.mem.eql(u8, raw_parsed.type, "exec"))
                .{ .primitive = .exec }
            else
                .{ .primitive = .{ .value = jsonStrToGraphlType.get(raw_parsed.type)
                    orelse {
                        std.log.err("Unknown graphl type json id: '{s}'", .{raw_parsed.type});
                        return error.UnknownField;
                    }
                }
                },
        };
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
    // TODO: consider adding a type wrapping ourselves
    //type: Type,

    tags: []const []const u8 = &.{},
    /// a description of what the node does
    description: ?[]const u8 = null,
    context: *const anyopaque,
    // TODO: do I really need pointers? The types are all going to be well defined aggregates,
    // and the nodes too
    // FIXME: read https://pithlessly.github.io/allocgate.html, the same logic as to why zig
    // stopped using @fieldParentPtr-based polymorphism applies here to, this is needlessly slow
    _getInputs: *const fn (*const NodeDesc) []const Pin,
    _getOutputs: *const fn (*const NodeDesc) []const Pin,
    /// name is relative to the env it is stored in
    _getName: *const fn (*const NodeDesc) [:0]const u8,

    pub fn name(self: *const @This()) [:0]const u8 {
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
        routine,
        pure,
        simpleBranch,
    };

    pub inline fn isSimpleBranch(self: *const @This()) bool {
        const is_branch = self == &builtin_nodes.@"if";
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
    name: [:0]u8,
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

        // FIXME: should be able to sink multiple source execs to one target
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
        // FIXME: is this even used...? very confusing
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

// place holder during analysis // FIXME: rename to unresolved_type
pub const empty_type: Type = &TypeInfo{ .name = "EMPTY_TYPE", .size = 0 };

// FIXME: consider renaming to "builtin_types"
pub const primitive_types = struct {
    // nums
    pub const i32_: Type = &TypeInfo{ .name = "i32", .size = 4 };
    pub const i64_: Type = &TypeInfo{ .name = "i64", .size = 8 };
    pub const u32_: Type = &TypeInfo{ .name = "u32", .size = 4 };
    pub const u64_: Type = &TypeInfo{ .name = "u64", .size = 8 };
    pub const f32_: Type = &TypeInfo{ .name = "f32", .size = 4 };
    pub const f64_ = &TypeInfo{ .name = "f64", .size = 8 };

    // FIXME: size of 4 for now, but is packed in arrays
    pub const byte: Type = &TypeInfo{ .name = "byte", .size = 4 };
    // FIXME: size of 4 for now, but is packed in arrays
    pub const bool_: Type = &TypeInfo{ .name = "bool", .size = 4 };
    // FIXME: size of 4 for now, but is packed in arrays
    pub const char_: Type = &TypeInfo{ .name = "char", .size = 4 };
    pub const symbol: Type = &TypeInfo{ .name = "symbol", .size = 4 };
    // FIXME: consolidate with empty type
    pub const @"void": Type = &TypeInfo{ .name = "void", .size = 0 };

    // FIXME: consider moving this to live in compound_types
    pub const string: Type = &TypeInfo{
        .name = "string",
        // FIXME: size is host-dependent, so should not be here tbh...
        .size = 0,
    };

    pub const rgba: Type = &TypeInfo{ .name = "rgba", .size = 4 };

    // FIXME: replace when we think out the macro system
    pub const code: Type = &TypeInfo{
        .name = "code",
        // FIXME: figure out what the size is of heap types
        // in wasm-gc
        .size = @sizeOf(usize),
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

/// these types are not always compiled in unless used from the standard library
pub const nonprimitive_types = struct {
    pub const vec3: Type = &TypeInfo{
        .name = "vec3",
        .size = @sizeOf(Vec3),
        .subtype = .{ .@"struct" = .{
            .field_names = &.{ "x", "y", "z" },
            .field_types = &.{ primitive_types.f64_, primitive_types.f64_, primitive_types.f64_ },
            .field_offsets = &.{ 0, 8, 16 },
            .size = 24,
            .flat_array_count = 0,
            .flat_primitive_slot_count = 3,
        } },
    };
};

pub const BasicNodeDesc = struct {
    name: [:0]const u8,
    hidden: bool = false,
    description: ?[]const u8 = null,
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

        pub fn getName(node: *const NodeDesc) [:0]const u8 {
            const desc: *const BasicNodeDesc = @alignCast(@ptrCast(node.context));
            return desc.name;
        }
    };

    return NodeDesc{
        .context = @ptrCast(in_desc),
        .hidden = in_desc.hidden,
        .kind = in_desc.kind,
        .tags = in_desc.tags,
        .description = in_desc.description,
        ._getInputs = BasicNodeImpl.getInputs,
        ._getOutputs = BasicNodeImpl.getOutputs,
        ._getName = BasicNodeImpl.getName,
    };
}

pub const BasicMutNodeDesc = struct {
    name: [:0]const u8,
    description: ?[]const u8 = null,
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

        pub fn getName(node: *const NodeDesc) [:0]const u8 {
            const desc: *const BasicMutNodeDesc = @alignCast(@ptrCast(node.context));
            return desc.name;
        }
    };

    return NodeDesc{
        .context = @ptrCast(in_desc),
        .hidden = in_desc.hidden,
        .kind = in_desc.kind,
        .tags = in_desc.tags,
        .description = in_desc.description,
        ._getInputs = BasicMutNodeImpl.getInputs,
        ._getOutputs = BasicMutNodeImpl.getOutputs,
        ._getName = BasicMutNodeImpl.getName,
    };
}

pub const BreakNodeContext = struct {
    struct_type: Type,
    out_pins: []const Pin,

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.dealloc(self.out_pins);
    }
};

pub const builtin_nodes = struct {
    // FIXME: replace with real macro system that isn't JSON hack
    pub const json_quote: NodeDesc = basicNode(&.{
        .name = "quote",
        .hidden = true, // FIXME: fix and unhide
        .inputs = &.{
            Pin{ .name = "code", .kind = .{ .primitive = .{ .value = primitive_types.code } } },
        },
        .outputs = &.{
            // TODO: this should output a sexp type
            Pin{ .name = "data", .kind = .{ .primitive = .{ .value = primitive_types.code } } },
        },
        .tags = &.{"json"},
        .description = "convert code into an array of instructions for post-processing",
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
        .description = "add any numbers together",
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
        .description = "subtract any numbers from each other",
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
        .description = "get the maximum of two numbers",
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
        .description = "get the minimum of two numbers",
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
        .description = "multiply any numbers from each other",
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
        .description = "divide any numbers from each other",
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
        .description = "returns true if a is greater than or equal to b, false otherwise",
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
        .description = "returns true if a is less than or equal to b, false otherwise",
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
        .description = "returns true if a is less than b, false otherwise",
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
        .description = "returns true if a is greater than b, false otherwise",
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
        .description = "returns true if a is equal to b, false otherwise. Don't use this for f32, f64",
        // FIXME: implement a floating point equality with tolerance
        //.description = "returns true if a is equal to b, false otherwise. Use almost-equal for f32, f64",
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
        .description = "returns true if a is not equal to b, false otherwise. Don't use this for f32, f64",
        .tags = &.{"comparison"},
    });

    pub const not: NodeDesc = basicNode(&.{
        .name = "not",
        .inputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .tags = &.{"boolean"},
        .description = "returns the opposite boolean value of the input. True if false, false if true",
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
        .description = "returns true only if both inputs are true, false otherwise",
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
        .description = "returns true if at least one input is true, false otherwise",
    });

    pub const @"if": NodeDesc = basicNode(&.{
        .name = "if",
        .inputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .exec } },
            Pin{ .name = "condition", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .outputs = &.{
            Pin{ .name = "then", .kind = .{ .primitive = .exec } },
            Pin{ .name = "else", .kind = .{ .primitive = .exec } },
        },
        .tags = &.{"control flow"},
        .description = "directs control flow of the program based on a boolean condition.",
    });

    pub const select: NodeDesc = basicNode(&.{
        .name = "select",
        .inputs = &.{
            // FIXME: support abstract types!
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
            Pin{ .name = "condition", .kind = .{ .primitive = .{ .value = primitive_types.bool_ } } },
        },
        .outputs = &.{
            Pin{ .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .tags = &.{"control flow"},
        .description = "if condition is true, return the first value, return the second otherwise",
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
        .description = "returns true if both input strings contain the same bytes in order",
        // FIXME: currently this function is unimplemented, so hiding for now
        .hidden = true,
    });

    // TODO: allow variadic arguments
    // FIXME: rename to join
    pub const string_concat: NodeDesc = basicNode(&.{
        .name = "Join",
        .inputs = &.{
            Pin{ .name = "a", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
            Pin{ .name = "b", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .outputs = &.{
            Pin{ .name = "result", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .tags = &.{"string"},
        .description = "concatenates two strings such that you have one string containing the bytes of a then of b",
    });

    // FIXME: replace with rgba "break" struct
    pub const vec3_x: NodeDesc = basicNode(&.{
        .name = "Vec3->X",
        .inputs = &.{
            Pin{ .name = "Vec3", .kind = .{ .primitive = .{ .value = nonprimitive_types.vec3 } } },
        },
        .outputs = &.{
            Pin{ .name = "X", .kind = .{ .primitive = .{ .value = primitive_types.f64_ } } },
        },
        .tags = &.{"vector"},
        .description = "get the x component of a vec3",
    });
    pub const vec3_y: NodeDesc = basicNode(&.{
        .name = "Vec3->Y",
        .inputs = &.{
            Pin{ .name = "Vec3", .kind = .{ .primitive = .{ .value = nonprimitive_types.vec3 } } },
        },
        .outputs = &.{
            Pin{ .name = "Y", .kind = .{ .primitive = .{ .value = primitive_types.f64_ } } },
        },
        .tags = &.{"vector"},
        .description = "get the y component of a vec3",
    });
    pub const vec3_z: NodeDesc = basicNode(&.{
        .name = "Vec3->Z",
        .inputs = &.{
            Pin{ .name = "Vec3", .kind = .{ .primitive = .{ .value = nonprimitive_types.vec3 } } },
        },
        .outputs = &.{
            Pin{ .name = "Z", .kind = .{ .primitive = .{ .value = primitive_types.f64_ } } },
        },
        .tags = &.{"vector"},
        .description = "get the z component of a vec3",
    });

    pub const vec3_negate: NodeDesc = basicNode(&.{
        .name = "negate",
        .inputs = &.{
            Pin{ .kind = .{ .primitive = .{ .value = nonprimitive_types.vec3 } } },
        },
        .outputs = &.{
            Pin{ .kind = .{ .primitive = .{ .value = nonprimitive_types.vec3 } } },
        },
        .tags = &.{"vector"},
        .description = "get a new vector where each component is the negative of the original",
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
        .description = "get the red byte of an rgba value",
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
        .description = "get the green byte of an rgba value",
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
        .description = "get the blue byte of an rgba value",
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
        .description = "get the alpha byte of an rgba value",
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
        .description = "create an rgba from its components",
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
        .description = "return the first index of 'string' containing character 'char', or -1 if there is no such index",
    });

    pub const string_length: NodeDesc = basicNode(&.{
        .name = "Length",
        .inputs = &.{
            Pin{ .name = "string", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .tags = &.{"string"},
        .description = "return the length of the input string",
    });

    pub const make_string: NodeDesc = basicNode(&.{
        .name = "Make String",
        .inputs = &.{
            Pin{ .name = "string", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .tags = &.{"string"},
        .description = "create a string",
    });

    pub const make_symbol: NodeDesc = basicNode(&.{
        .name = "Make Symbol",
        .inputs = &.{
            Pin{ .name = "string", .kind = .{ .primitive = .{ .value = primitive_types.string } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .{ .value = primitive_types.symbol } } },
        },
        .tags = &.{"symbol"},
        .description = "create a symbol from a string",
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
            Pin{ .name = "", .kind = .{ .primitive = .exec } },
            Pin{ .name = "variable", .kind = .{ .primitive = .{ .value = primitive_types.symbol } } },
            Pin{ .name = "new value", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "", .kind = .{ .primitive = .exec } },
            Pin{ .name = "value", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .tags = &.{"state"},
        .description = "set a value to some variable",
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

test "node types" {
    try std.testing.expectEqual(
        builtin_nodes.@"+".getOutputs()[0].kind.primitive.value,
        primitive_types.i32_,
    );
}

pub const Env = struct {
    parentEnv: ?*const Env = null,

    // TODO: use symbols/interning maybe for type names?
    // FIXME: store struct types separately
    _struct_types: std.StringHashMapUnmanaged(StructType) = .{},
    _types: std.StringHashMapUnmanaged(Type) = .{},
    // FIXME: actually separate each of those possibilities!
    // could be macro, function, operator, should be in a separate array
    _nodes: std.StringHashMapUnmanaged(*const NodeDesc) = .{},

    // TODO: scoped tags
    /// the root env owns the pointer, descendents just share it
    _nodes_by_tag: *TagNodesMap,
    /// the root env owns the pointer, descendents just share it
    _nodes_by_type: *TypeNodesMap,
    /// the root env owns the pointer, descendents just share it
    _tag_set: *TagSet,

    // TODO: consider using SegmentedLists of each type (SoE)
    created_types: std.SinglyLinkedList(TypeInfo) = .{},
    created_nodes: std.SinglyLinkedList(NodeDesc) = .{},

    const TagSet = std.StringArrayHashMapUnmanaged(void);
    const NodeSet = std.AutoHashMapUnmanaged(*const NodeDesc, void);
    const TypeNodesMap = std.AutoHashMapUnmanaged(Type, NodeSet);
    const TagNodesMap = std.StringHashMapUnmanaged(NodeSet);

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        if (self.parentEnv == null) {
            {
                var nodes_by_tag_iter = self._nodes_by_tag.iterator();
                while (nodes_by_tag_iter.next()) |node_list| node_list.value_ptr.*.deinit(alloc);
                self._nodes_by_tag.clearAndFree(alloc);
            }
            {
                var nodes_by_type_iter = self._nodes_by_type.iterator();
                while (nodes_by_type_iter.next()) |node_list| node_list.value_ptr.*.deinit(alloc);
                self._nodes_by_type.clearAndFree(alloc);
            }
            self._tag_set.clearAndFree(alloc);
            alloc.destroy(self._nodes_by_tag);
            alloc.destroy(self._nodes_by_type);
            alloc.destroy(self._tag_set);
        }
        self._types.clearAndFree(alloc);
        self._nodes.clearAndFree(alloc);
        while (self.created_nodes.popFirst()) |popped| alloc.destroy(popped);
        while (self.created_types.popFirst()) |popped| alloc.destroy(popped);
        // FIXME: destroy all created slots
    }

    pub fn spawn(self: *const @This()) @This() {
        return @This(){
            .parentEnv = self,
            ._nodes_by_tag = self._nodes_by_tag,
            ._nodes_by_type = self._nodes_by_type,
            ._tag_set = self._tag_set,
        };
    }

    pub fn initDefault(alloc: std.mem.Allocator) !@This() {
        var env = @This(){
            ._nodes_by_tag = try alloc.create(TagNodesMap),
            ._nodes_by_type = try alloc.create(TypeNodesMap),
            ._tag_set = try alloc.create(TagSet),
        };
        env._nodes_by_tag.* = .{};
        env._nodes_by_type.* = .{};
        env._tag_set.* = .{};

        inline for (&.{ primitive_types, nonprimitive_types }) |types| {
            //const types_decls = comptime std.meta.declList(types, TypeInfo);
            const types_decls = comptime std.meta.declarations(types);
            try env._types.ensureTotalCapacity(alloc, @intCast(types_decls.len));
            inline for (types_decls) |d| {
                const type_ = @field(types, d.name);
                try env._types.put(alloc, type_.name, type_);
            }
        }

        inline for (&.{ builtin_nodes }) |nodes| {
            // TODO: select by type so we can make public other types
            //const nodes_decls = std.meta.declList(nodes, NodeDesc);
            const nodes_decls = comptime std.meta.declarations(nodes);
            try env._nodes.ensureTotalCapacity(alloc, @intCast(nodes_decls.len));
            inline for (nodes_decls) |n| {
                const node = @field(nodes, n.name);
                try env._nodes.put(alloc, node.name(), &@field(nodes, n.name));
                try env.registerNode(alloc, &@field(nodes, n.name));
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

    pub fn tagIterator(self: *@This()) []const []const u8 {
        return self._tag_set.keys();
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

    /// NOTE: this only currently only works at the most descendent env
    pub fn nodeByTagIterator(self: *@This(), tag: []const u8) ?NodeSet.KeyIterator {
        return if (self._nodes_by_tag.getPtr(tag)) |node_set| node_set.keyIterator() else null;
    }

    /// NOTE: this only currently only works at the most descendent env
    pub fn nodeByTypeIterator(self: *@This(), type_: Type) ?NodeSet.KeyIterator {
        return if (self._nodes_by_type.getPtr(type_)) |node_set| node_set.keyIterator() else null;
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
        if (result.found_existing) {
            return error.EnvAlreadyExists;
        }
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
        if (result.found_existing) {
            return error.EnvAlreadyExists;
        }
        const slot = try a.create(std.SinglyLinkedList(NodeDesc).Node);
        slot.* = .{
            .data = node_desc,
            .next = null,
        };
        self.created_nodes.prepend(slot);
        result.value_ptr.* = &slot.data;

        try self.registerNode(a, &slot.data);

        return &slot.data;
    }

    pub fn registerNode(self: *@This(), a: std.mem.Allocator, node_desc: *const NodeDesc) !void {
        for (node_desc.tags) |tag| {
            try self._tag_set.put(a, tag, {});
            const tag_set_res = try self._nodes_by_tag.getOrPut(a, tag);
            if (!tag_set_res.found_existing) {
                tag_set_res.value_ptr.* = .{};
            }
            const tag_set = tag_set_res.value_ptr;
            try tag_set.putNoClobber(a, node_desc, {});
        }

        // FIXME: make a better way to get untagged nodes
        if (node_desc.tags.len == 0) {
            const tag = "other";
            try self._tag_set.put(a, tag, {});
            const tag_set_res = try self._nodes_by_tag.getOrPut(a, tag);
            if (!tag_set_res.found_existing) {
                tag_set_res.value_ptr.* = .{};
            }
            const tag_set = tag_set_res.value_ptr;
            try tag_set.putNoClobber(a, node_desc, {});
        }

        for (node_desc.getInputs()) |input| {
            if (input.asPrimitivePin() != .value)
                continue;
            const pin_type = input.asPrimitivePin().value;
            const type_set_res = try self._nodes_by_type.getOrPut(a, pin_type);
            if (!type_set_res.found_existing)
                type_set_res.value_ptr.* = .{};
            const type_set = type_set_res.value_ptr;
            try type_set.put(a, node_desc, {});
        }

        for (node_desc.getOutputs()) |output| {
            if (output.asPrimitivePin() != .value)
                continue;
            const pin_type = output.asPrimitivePin().value;
            const type_set_res = try self._nodes_by_type.getOrPut(a, pin_type);
            if (!type_set_res.found_existing)
                type_set_res.value_ptr.* = .{};
            const type_set = type_set_res.value_ptr;
            try type_set.put(a, node_desc, {});
        }
    }
};

test "env" {
    var env = try Env.initDefault(std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env._types.contains("u32"));
}
