pub const MenuOptionJson = struct {
    name: []const u8,
    on_click_handle: u32,
    submenus: []const MenuOptionJson = &.{},
};

// TODO: just use dvui.Point
pub const PtJson = struct { x: f32 = 0.0, y: f32 = 0.0 };

// TODO: make all these InitState types JSON capable natively, removing most of this file I think
pub const InputInitStateJson = App.InputInitState;
pub const NodeInitStateJson = App.NodeInitState;
pub const GraphInitStateJson = App.GraphInitState;
pub const GraphsInitStateJson = std.json.ArrayHashMap(GraphInitStateJson);

// FIXME: copied in some places and replaced by raw Graphl.Pin
// CONSOLIDATE
pub const PinJson = struct {
    name: [:0]const u8,
    description: ?[:0]const u8 = null,
    type: []const u8,

    pub fn promote(self: @This()) !helpers.Pin {
        return helpers.Pin{
            .name = self.name,
            .description = self.description,
            .kind = if (std.mem.eql(u8, self.type, "exec"))
                .{ .primitive = .exec }
            else
                .{ .primitive = .{ .value = helpers.jsonStrToGraphlType.get(self.type) orelse return error.NotGraphlType } },
        };
    }
};

pub const BasicMutNodeDescJson = struct {
    name: [:0]const u8,
    hidden: bool = false,
    description: ?[]const u8 = null,
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
        try result.put(a, entry.key_ptr.*, entry.value_ptr.*);
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
                .description = entry.value_ptr.node.description,
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
