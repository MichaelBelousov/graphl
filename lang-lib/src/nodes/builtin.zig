//! builtin nodes

const TypeInfo = struct {
    name: []const u8,
};

const Type = *const TypeInfo;

const TypeSpecifier = union {
    specific: Type,
    //enum_values: []const enum_value,
    union_: []const TypeInfo,
    struct_: []const TypeInfo,
};

const Input = struct {
    type_specifier: TypeSpecifier,
    //default: Value,
};

const Node = struct {
    type_: Type,
    inputs: []const Input,
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
};

/// lisp-like tree, first is value, rest are children
const num_type_hierarchy = .{
    primitive_types.nums.f64_,
    .{ primitive_types.nums.f32_,
        .{ primitive_types.nums.i64_, .{ primitive_types.nums.i32_ } },
        .{ primitive_types.nums.u64_, .{ primitive_types.nums.u32_ } } },
};

fn resolvePeerNumType(types: []const Type) Type {
    const Local = struct { fn resolvePair(t: Type, u: Type) Type {
        // TODO: generate this at comptime :)
        return switch (t) {
            primitive_types.nums.f32_ => switch (u) {
                primitive_types.nums.f32_ => primitive_types.nums.f32_,
                primitive_types.nums.f64_ => primitive_types.nums.f64_,
            }
        };
    } };

    //std.meta.window
    // for (types) |t| {

    // }
}

fn returnType(builtin_node: *const Node, input_types: []const Type) Type {
    return switch (*builtin_node) {
        builtin_nodes.@"+" => resolvePeerNumType(input_types),
        builtin_nodes.@"-" => resolvePeerNumType(input_types),
    };
}

const builtin_nodes = struct {
    const @"+" = Node{
    };
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

