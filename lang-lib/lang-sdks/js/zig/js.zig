pub const Diagnostic = struct {
    @"error": []const u8 = "",
};

pub fn compileSource(
    a: std.mem.Allocator,
    file_name: []const u8,
    src: []const u8,
    user_func_json: []const u8,
    out_diag_ptr: ?*Diagnostic,
) ![]const u8 {
    _ = file_name; // FIXME

    var parse_diag = graphl.SexpParser.Diagnostic{ .source = src };
    var parsed = graphl.SexpParser.parse(a, src, &parse_diag) catch |err| {
        if (out_diag_ptr) |out_diag| {
            out_diag.@"error" = try std.fmt.allocPrint(a, "{}", .{parse_diag});
        }
        return err;
    };
    defer parsed.deinit();

    var diagnostic = graphl.compiler.Diagnostic.init();

    var user_funcs = _: {
        var user_funcs = std.SinglyLinkedList(graphl.compiler.UserFunc){};

        var json_arena = std.heap.ArenaAllocator.init(a);
        defer json_arena.deinit();

        const user_funcs_parsed = try std.json.parseFromSlice(std.json.ArrayHashMap(UserFuncJson), a, user_func_json, .{ .ignore_unknown_fields = true });
        // FIXME: this causes a leak that can't be fixed
        // do not deallocate on success so we can keep pointers into the json
        errdefer user_funcs_parsed.deinit();

        var entry_iter = user_funcs_parsed.value.map.iterator();
        while (entry_iter.next()) |entry| {
            const new_node = try a.create(std.SinglyLinkedList(graphl.compiler.UserFunc).Node);

            const inputs = try a.alloc(graphl.helpers.Pin, entry.value_ptr.node.inputs.len + 1);
            inputs[0] = graphl.helpers.Pin{ .name = "", .kind = .{ .primitive = .exec } };
            errdefer a.free(inputs);
            for (entry.value_ptr.node.inputs, inputs[1..]) |input_json, *input| {
                input.* = try input_json.promote();
            }

            const outputs = try a.alloc(graphl.helpers.Pin, entry.value_ptr.node.outputs.len + 1);
            outputs[0] = graphl.helpers.Pin{ .name = "", .kind = .{ .primitive = .exec } };
            // FIXME: this errdefer doesn't free in all loop iterations!
            errdefer a.free(outputs);
            for (entry.value_ptr.node.outputs, outputs[1..]) |output_json, *output| {
                output.* = try output_json.promote();
            }

            new_node.* = .{
                .data = .{
                    .id = entry.value_ptr.id,
                    .node = .{
                        .name = entry.value_ptr.node.name,
                        .tags = entry.value_ptr.node.tags,
                        .hidden = entry.value_ptr.node.hidden,
                        .inputs = inputs,
                        .outputs = outputs,
                        .kind = entry.value_ptr.node.kind,
                    },
                },
            };

            user_funcs.prepend(new_node);
        }

        break :_ user_funcs;
    };

    return graphl.compiler.compile(a, &parsed.module, &user_funcs, &diagnostic) catch |err| {
        if (out_diag_ptr) |out_diag| {
            out_diag.@"error" = try std.fmt.allocPrint(a, "{}", .{diagnostic});
        }
        return err;
    };
}

pub const PinJson = struct {
    name: [:0]const u8,
    type: []const u8,

    pub fn promote(self: @This()) !graphl.helpers.Pin {
        return graphl.helpers.Pin{
            .name = self.name,
            .kind = if (std.mem.eql(u8, self.type, "exec"))
                .{ .primitive = .exec }
            else
                .{ .primitive = .{ .value = jsonStrToGraphlType.get(self.type) orelse return error.NotGraphlType } },
        };
    }
};

pub const BasicMutNodeDescJson = struct {
    name: [:0]const u8,
    hidden: bool = false,
    kind: graphl.helpers.NodeDescKind = .func,
    inputs: []PinJson = &.{},
    outputs: []PinJson = &.{},
    tags: []const []const u8 = &.{},
};

pub const UserFuncJson = struct {
    id: usize,
    node: BasicMutNodeDescJson,
};

// FIXME: just use a default env
const jsonStrToGraphlType: std.StaticStringMap(graphl.Type) = _: {
    break :_ std.StaticStringMap(graphl.Type).initComptime(.{
        .{ "u32", graphl.primitive_types.u32_ },
        .{ "u64", graphl.primitive_types.u64_ },
        .{ "i32", graphl.primitive_types.i32_ },
        .{ "i64", graphl.primitive_types.i64_ },
        .{ "f32", graphl.primitive_types.f32_ },
        .{ "f64", graphl.primitive_types.f64_ },
        .{ "string", graphl.primitive_types.string },
        .{ "code", graphl.primitive_types.code },
        .{ "bool", graphl.primitive_types.bool_ },
        .{ "rgba", graphl.primitive_types.rgba },
        .{ "vec3", graphl.primitive_types.vec3 },
    });
};


const std = @import("std");
const graphl = @import("graphl");
