// FIXME
var app: App = .{};
var init_opts: App.InitOptions = .{};

pub const MenuOptionJson = struct {
    name: []const u8,
    on_click_handle: u32,
    submenus: []const MenuOptionJson = &.{},
};

// TODO: just use dvui.Point
const PtJson = struct { x: f32 = 0.0, y: f32 = 0.0 };

pub const InputInitStateJson = App.InputInitState;

pub const NodeInitStateJson = struct {
    id: usize,
    /// type of node, e.g. "+"
    type: []const u8,
    // keys should be u16
    inputs: std.json.ArrayHashMap(InputInitStateJson) = .{},
    position: ?PtJson = null,
};

pub const GraphInitStateJson = struct {
    notRemovable: bool = false,
    nodes: []NodeInitStateJson = &.{},
};

pub const GraphsInitStateJson = std.json.ArrayHashMap(GraphInitStateJson);

pub const BasicMutNodeDescJson = struct {
    name: []const u8,
    hidden: bool = false,
    kind: helpers.NodeDescKind = .func,
    inputs: []helpers.Pin = &.{},
    outputs: []helpers.Pin = &.{},
    tags: []const []const u8 = &.{},
};

pub const UserFuncJson = struct {
    id: usize,
    node: BasicMutNodeDescJson,
};

pub const InitOptsJson = struct {
    menus: []const MenuOptionJson = &.{},
    graphs: GraphsInitStateJson = .{},
    user_funcs: std.json.ArrayHashMap(UserFuncJson) = .{},

    allow_running: bool = true,
    preferences: struct {
        graph: struct {
            origin: ?PtJson = null,
            scale: ?f32 = null,
            scrollBarsVisible: ?bool = false,
            allowPanning: bool = true,
        } = .{},
        definitionsPanel: struct {
            orientation: App.Orientation = .left,
            visible: bool = true,
        } = .{},
        topbar: struct {
            visible: bool = true,
        } = .{},
    } = .{},
};

pub fn init() !void {
    if (init_opts.result_buffer == null) {
        @panic("setInitOpts hasn't been called before init!");
    }
    try App.init(&app, init_opts);
}

pub fn deinit() void {
    app.deinit();
}

pub fn frame() !void {
    try app.frame();
}

// NOTE: check if this is bad
const graphl_init_buffer: [std.wasm.page_size]u8 = _: {
    var result = std.mem.zeroes([std.wasm.page_size]u8);
    result[0] = '\x1B';
    result[1] = '\x2D';
    result[std.wasm.page_size - 2] = '\x3E';
    result[std.wasm.page_size - 1] = '\x4F';
    break :_ result;
};

export const graphl_init_start: [*]const u8 = switch (builtin.mode) {
    //.Debug => &graphl_init_buffer[0],
    else => @ptrCast(&graphl_init_buffer[0]),
};

// fuck it just ship this crap, WTF: REPORT ME HACK FIXME
const init_buff_offset: isize = switch (builtin.mode) {
    .Debug => 0,
    else => 0,
};

const graphl_real_init_buff: *const [std.wasm.page_size]u8 = @ptrCast(graphl_init_start + init_buff_offset);

// TODO: also a result size global
export var result_buffer = std.mem.zeroes([4096]u8);

export fn _runCurrentGraphs() void {
    app.runCurrentGraphs() catch |e| {
        std.log.err("Error running: {}", .{e});
    };
}

export fn onReceiveLoadedSource(in_ptr: ?[*]const u8, len: usize) void {
    const src = (in_ptr orelse return)[0..len];

    app.onReceiveLoadedSource(src) catch |err| {
        std.log.err("sourceToGraph error: {}", .{err});
        return;
    };
}

export fn setInitOpts(json_ptr: ?[*]const u8, json_len: usize) bool {
    const json = (json_ptr orelse return false)[0..json_len];
    _setInitOpts(json) catch return false;
    return true;
}

extern fn on_menu_click(handle: u32) void;

fn onMenuClick(_: ?*anyopaque, click_ctx: ?*anyopaque) void {
    on_menu_click(@intFromPtr(click_ctx));
}

fn _setInitOpts(json: []const u8) !void {
    const init_opts_json = try std.json.parseFromSlice(InitOptsJson, gpa, json, .{});
    errdefer init_opts_json.deinit();

    const Local = struct {
        pub fn convertMenus(menus_json: []const MenuOptionJson) ![]App.MenuOption {
            const menus = try gpa.alloc(App.MenuOption, menus_json.len);
            for (menus_json, menus) |menu_json, *menu| {
                menu.* = .{
                    .name = menu_json.name,
                    .on_click = onMenuClick,
                    .on_click_ctx = @ptrFromInt(menu_json.on_click_handle),
                    .submenus = try convertMenus(menu_json.submenus),
                };
            }
            return menus;
        }

        pub fn convertGraphs(graphs: GraphsInitStateJson) !App.GraphsInitState {
            var result = App.GraphsInitState{};
            errdefer result.deinit(gpa);

            var iter = graphs.map.iterator();
            while (iter.next()) |entry| {
                const nodes = try gpa.alloc(App.NodeInitState, entry.value_ptr.nodes.len);
                errdefer gpa.free(nodes);

                for (entry.value_ptr.nodes, nodes) |node_json, *node| {
                    var inputs = std.AutoHashMapUnmanaged(u16, App.InputInitState){};
                    errdefer inputs.deinit(gpa);
                    var input_iter = node_json.inputs.map.iterator();
                    while (input_iter.next()) |input_json_entry| {
                        const key = try std.fmt.parseInt(u16, input_json_entry.key_ptr.*, 10);
                        switch (input_json_entry.value_ptr.*) {
                            inline else => |v, tag| try inputs.put(gpa, key, @unionInit(App.InputInitState, @tagName(tag), v)),
                        }
                    }

                    node.* = .{
                        .id = node_json.id,
                        .type_ = node_json.type,
                        .position = if (node_json.position) |p| .{ .x = p.x, .y = p.y } else .{},
                        .inputs = inputs,
                    };
                }

                try result.put(gpa, entry.key_ptr.*, .{
                    .nodes = std.ArrayListUnmanaged(App.NodeInitState).fromOwnedSlice(nodes),
                    .notRemovable = entry.value_ptr.notRemovable,
                });
            }

            return result;
        }

        pub fn convertUserFuncs(user_funcs_json: std.json.ArrayHashMap(UserFuncJson)) ![]graphl.compiler.UserFunc {
            var result = try gpa.alloc(graphl.compiler.UserFunc, user_funcs_json.map.count());

            var i: usize = 0;
            var iter = user_funcs_json.map.iterator();
            while (iter.next()) |entry| : (i += 1) {
                result[i] = .{
                    .id = entry.value_ptr.id,
                    .node = .{
                        .name = entry.value_ptr.node.name,
                        .tags = entry.value_ptr.node.tags,
                        .hidden = entry.value_ptr.node.hidden,
                        .inputs = entry.value_ptr.node.inputs,
                        .outputs = entry.value_ptr.node.outputs,
                        .kind = entry.value_ptr.node.kind,
                    },
                };
            }

            return result;
        }
    };

    const menus = try Local.convertMenus(init_opts_json.value.menus);
    // FIXME: need to recursively free menus! submenus leak right now
    errdefer gpa.free(menus);

    var graphs = try Local.convertGraphs(init_opts_json.value.graphs);
    errdefer graphs.deinit(gpa);

    const user_funcs = try Local.convertUserFuncs(init_opts_json.value.user_funcs);
    errdefer user_funcs.deinit(gpa);

    app.init_opts = .{
        .result_buffer = &result_buffer,
        .menus = menus,
        .graphs = graphs,
        .user_funcs = user_funcs,
        .allow_running = true,
        .preferences = .{
            .graph = .{
                .origin = if (init_opts_json.value.preferences.graph.origin) |p| .{ .x = p.x, .y = p.y } else null,
                .scale = init_opts_json.value.preferences.graph.scale,
                .scrollBarsVisible = init_opts_json.value.preferences.graph.scrollBarsVisible,
                .allowPanning = init_opts_json.value.preferences.graph.allowPanning,
            },
            .definitionsPanel = .{
                .orientation = init_opts_json.value.preferences.definitionsPanel.orientation,
                .visible = init_opts_json.value.preferences.definitionsPanel.visible,
            },
            .topbar = .{
                .visible = init_opts_json.value.preferences.topbar.visible,
            },
        },
    };
}

const gpa = App.gpa;
const graphl = @import("grappl_core");
const helpers = @import("grappl_core").helpers;
const sourceToGraph = @import("./source_to_graph.zig").sourceToGraph;

const App = @import("./app.zig");
const std = @import("std");
const builtin = @import("builtin");
