pub const MenuOptionJson = struct {
    name: []const u8,
    on_click_handle: u32,
    submenus: []const MenuOptionJson = &.{},
};

// TODO: just use dvui.Point
pub const PtJson = struct { x: f32 = 0.0, y: f32 = 0.0 };

// TODO: make all these InitState types JSON capable natively
pub const InputInitStateJson = App.InputInitState;

pub const NodeInitStateJson = App.NodeInitState;

pub const GraphInitStateJson = struct {
    fixedSignature: bool = false,
    nodes: []NodeInitStateJson = &.{},
    inputs: ?[]const PinJson = &.{},
    outputs: ?[]const PinJson = &.{},
};

pub const GraphsInitStateJson = std.json.ArrayHashMap(GraphInitStateJson);

// FIXME: copied by compiler js sdk, should move up and share
pub const PinJson = struct {
    name: [:0]const u8,
    type: []const u8,

    pub fn promote(self: @This()) !helpers.Pin {
        return helpers.Pin{
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
    kind: enum { func, pure } = .func,
    inputs: []PinJson = &.{},
    outputs: []PinJson = &.{},
    tags: []const []const u8 = &.{},
};

pub const UserFuncJson = struct {
    id: usize,
    node: BasicMutNodeDescJson,
};

pub const InitOptsJson = struct {
    menus: ?[]const MenuOptionJson = &.{},
    graphs: ?GraphsInitStateJson = .{},
    userFuncs: ?std.json.ArrayHashMap(UserFuncJson) = .{},

    allowRunning: ?bool = true,
    preferences: ?struct {
        graph: ?struct {
            origin: ?PtJson = null,
            scale: ?f32 = null,
            scrollBarsVisible: ?bool = false,
            allowPanning: ?bool = true,
        } = .{},
        definitionsPanel: ?struct {
            orientation: ?App.Orientation = .left,
            visible: ?bool = true,
        } = .{},
        topbar: ?struct {
            visible: ?bool = true,
        } = .{},
    } = .{},
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

pub fn convertMenus(a: std.mem.Allocator, menus_json: []const MenuOptionJson, comptime onMenuClick: fn(?*anyopaque, ?*anyopaque) void) ![]App.MenuOption {
    const menus = try a.alloc(App.MenuOption, menus_json.len);
    for (menus_json, menus) |menu_json, *menu| {
        menu.* = .{
            .name = menu_json.name,
            .on_click = onMenuClick,
            .on_click_ctx = @ptrFromInt(menu_json.on_click_handle),
            .submenus = try convertMenus(a, menu_json.submenus, onMenuClick),
        };
    }
    return menus;
}

pub fn convertGraphs(a: std.mem.Allocator, graphs: GraphsInitStateJson) !App.GraphsInitState {
    var result = App.GraphsInitState{};
    errdefer result.deinit(a);

    var iter = graphs.map.iterator();
    while (iter.next()) |entry| {
        const nodes = try a.alloc(App.NodeInitState, entry.value_ptr.nodes.len);
        errdefer a.free(nodes);

        for (entry.value_ptr.nodes, nodes) |node_json, *node| {
            var inputs = std.AutoHashMapUnmanaged(u16, App.InputInitState){};
            errdefer inputs.deinit(a);
            var input_iter = node_json.inputs.iterator();
            while (input_iter.next()) |input_json_entry| {
                const key = input_json_entry.key_ptr.*;
                switch (input_json_entry.value_ptr.*) {
                    inline .string, .symbol => |v, tag| {
                        try inputs.put(
                            a,
                            key,
                            @unionInit(App.InputInitState, @tagName(tag), try a.dupeZ(u8, v)),
                        );
                    },
                    inline else => |v, tag| try inputs.put(
                        a,
                        key,
                        @unionInit(App.InputInitState, @tagName(tag), v),
                    ),
                }
            }

            node.* = .{
                .id = node_json.id,
                .type_ = node_json.type_,
                .position = if (node_json.position) |p| .{ .x = p.x, .y = p.y } else .{},
                .inputs = inputs,
            };
        }

        const inputs_json = entry.value_ptr.inputs orelse &.{};
        const inputs = try a.alloc(helpers.Pin, inputs_json.len);
        errdefer a.free(inputs);
        for (inputs_json, inputs) |input_json, *input| {
            input.* = try input_json.promote();
        }

        const outputs_json = entry.value_ptr.outputs orelse &.{};
        const outputs = try a.alloc(helpers.Pin, outputs_json.len);
        // FIXME: this errdefer doesn't free in all loop iterations!
        errdefer a.free(outputs);
        for (outputs_json, outputs) |output_json, *output| {
            output.* = try output_json.promote();
        }

        try result.put(a, entry.key_ptr.*, .{
            .nodes = std.ArrayListUnmanaged(App.NodeInitState).fromOwnedSlice(nodes),
            .fixed_signature = entry.value_ptr.fixedSignature,
            .parameters = inputs,
            .results = outputs,
        });
    }

    return result;
}

pub fn convertUserFuncs(a: std.mem.Allocator, user_funcs_json: std.json.ArrayHashMap(UserFuncJson)) ![]graphl.compiler.UserFunc {
    var result = try a.alloc(graphl.compiler.UserFunc, user_funcs_json.map.count());

    var i: usize = 0;
    var iter = user_funcs_json.map.iterator();
    while (iter.next()) |entry| : (i += 1) {
        const inputs = try a.alloc(helpers.Pin, entry.value_ptr.node.inputs.len);
        errdefer a.free(inputs);
        for (entry.value_ptr.node.inputs, inputs) |input_json, *input| {
            input.* = try input_json.promote();
        }

        const outputs = try a.alloc(helpers.Pin, entry.value_ptr.node.outputs.len);
        // FIXME: this errdefer doesn't free in all loop iterations!
        errdefer a.free(outputs);
        for (entry.value_ptr.node.outputs, outputs) |output_json, *output| {
            output.* = try output_json.promote();
        }

        result[i] = .{
            .id = entry.value_ptr.id,
            .node = .{
                .name = entry.value_ptr.node.name,
                .tags = entry.value_ptr.node.tags,
                .hidden = entry.value_ptr.node.hidden,
                .inputs = inputs,
                .outputs = outputs,
                // FIXME: have a better interface
                .kind = switch (entry.value_ptr.node.kind) {
                    .func => .func,
                    .pure => .func,
                },
            },
        };
    }

    return result;
}

const graphl = @import("graphl_core");
// FIXME: move to util package
const IntArrayHashMap = @import("graphl_core").IntArrayHashMap;
const helpers = @import("graphl_core").helpers;

const App = @import("./app.zig");
const std = @import("std");
