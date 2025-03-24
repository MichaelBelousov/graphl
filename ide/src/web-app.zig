// FIXME: avoid globals until the consumer level
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
    inputs: IntArrayHashMap(u16, InputInitStateJson, 10) = .{},
    position: ?PtJson = null,
};

pub const GraphInitStateJson = struct {
    fixedSignature: bool = false,
    nodes: []NodeInitStateJson = &.{},
    inputs: ?[]const PinJson = &.{},
    outputs: ?[]const PinJson = &.{},
};

pub const GraphsInitStateJson = std.json.ArrayHashMap(GraphInitStateJson);

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
    kind: helpers.NodeDescKind = .func,
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

/// returns null if failure
export fn exportCurrentCompiled() void {
    app.exportCurrentCompiled() catch |err| {
        std.log.err("sourceToGraph error: {}", .{err});
        return;
    };
}

export fn setInitOpts(json_ptr: ?[*]const u8, json_len: usize) bool {
    const json = (json_ptr orelse return false)[0..json_len];
    _setInitOpts(json) catch |err| {
        std.log.err("error setting init options: {}", .{err});
        return false;
    };
    return true;
}

extern fn on_menu_click(handle: u32) void;

fn onMenuClick(_: ?*anyopaque, click_ctx: ?*anyopaque) void {
    on_menu_click(@intFromPtr(click_ctx));
}

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

fn _setInitOpts(in_json: []const u8) !void {
    const json = try gpa.dupe(u8, in_json);
    var arena = std.heap.ArenaAllocator.init(gpa);
    // NOTE: leaks on success, fix when switching to using globals
    //errdefer arena.deinit();

    var json_diagnostics = std.json.Diagnostics{};
    var json_scanner = std.json.Scanner.initCompleteInput(gpa, json);
    json_scanner.enableDiagnostics(&json_diagnostics);
    //json_scanner.deinit();
    const init_opts_json = std.json.parseFromTokenSourceLeaky(
        InitOptsJson,
        arena.allocator(),
        &json_scanner,
        // duplicate string tokens in case the transfer buffer is reused (FIXME: this leaks for now)
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch |err| {
        std.log.err("json parsing err: {}", .{err});
        std.log.err("byte={}, diagnostic={}", .{ json_diagnostics.getByteOffset(), json_diagnostics });
        return err;
    };

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
                        const key = input_json_entry.key_ptr.*;
                        switch (input_json_entry.value_ptr.*) {
                            inline .string, .symbol => |v, tag| {
                                try inputs.put(
                                    gpa,
                                    key,
                                    @unionInit(App.InputInitState, @tagName(tag), try gpa.dupeZ(u8, v)),
                                );
                            },
                            inline else => |v, tag| try inputs.put(
                                gpa,
                                key,
                                @unionInit(App.InputInitState, @tagName(tag), v),
                            ),
                        }
                    }

                    node.* = .{
                        .id = node_json.id,
                        .type_ = node_json.type,
                        .position = if (node_json.position) |p| .{ .x = p.x, .y = p.y } else .{},
                        .inputs = inputs,
                    };
                }

                const inputs_json = entry.value_ptr.inputs orelse &.{};
                const inputs = try gpa.alloc(helpers.Pin, inputs_json.len);
                errdefer gpa.free(inputs);
                for (inputs_json, inputs) |input_json, *input| {
                    input.* = try input_json.promote();
                }

                const outputs_json = entry.value_ptr.outputs orelse &.{};
                const outputs = try gpa.alloc(helpers.Pin, outputs_json.len);
                // FIXME: this errdefer doesn't free in all loop iterations!
                errdefer gpa.free(outputs);
                for (outputs_json, outputs) |output_json, *output| {
                    output.* = try output_json.promote();
                }

                try result.put(gpa, entry.key_ptr.*, .{
                    .nodes = std.ArrayListUnmanaged(App.NodeInitState).fromOwnedSlice(nodes),
                    .fixed_signature = entry.value_ptr.fixedSignature,
                    .parameters = inputs,
                    .results = outputs,
                });
            }

            return result;
        }

        pub fn convertUserFuncs(user_funcs_json: std.json.ArrayHashMap(UserFuncJson)) ![]graphl.compiler.UserFunc {
            var result = try gpa.alloc(graphl.compiler.UserFunc, user_funcs_json.map.count());

            var i: usize = 0;
            var iter = user_funcs_json.map.iterator();
            while (iter.next()) |entry| : (i += 1) {
                const inputs = try gpa.alloc(helpers.Pin, entry.value_ptr.node.inputs.len);
                errdefer gpa.free(inputs);
                for (entry.value_ptr.node.inputs, inputs) |input_json, *input| {
                    input.* = try input_json.promote();
                }

                const outputs = try gpa.alloc(helpers.Pin, entry.value_ptr.node.outputs.len);
                // FIXME: this errdefer doesn't free in all loop iterations!
                errdefer gpa.free(outputs);
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
                        .kind = entry.value_ptr.node.kind,
                    },
                };
            }

            return result;
        }
    };

    const menus: []const App.MenuOption = if (init_opts_json.menus) |m| try Local.convertMenus(m) else &.{};
    // FIXME: need to recursively free menus! submenus leak right now
    errdefer if (init_opts_json.menus != null) gpa.free(menus);

    var graphs: std.StringHashMapUnmanaged(App.GraphInitState) = if (init_opts_json.graphs) |g| try Local.convertGraphs(g) else .{};
    errdefer graphs.deinit(gpa);

    const user_funcs: []const graphl.compiler.UserFunc = if (init_opts_json.userFuncs) |uf| try Local.convertUserFuncs(uf) else &.{};
    errdefer if (init_opts_json.userFuncs != null) user_funcs.deinit(gpa);

    init_opts = .{
        .result_buffer = &result_buffer,
        .menus = menus,
        .graphs = graphs,
        .user_funcs = user_funcs,
        .allow_running = init_opts_json.allowRunning orelse true,
        .preferences = if (init_opts_json.preferences) |prefs| .{
            .graph = if (prefs.graph) |graph_prefs| .{
                .origin = if (graph_prefs.origin) |p| .{ .x = p.x, .y = p.y } else null,
                .scale = graph_prefs.scale,
                .scrollBarsVisible = graph_prefs.scrollBarsVisible orelse false,
                .allowPanning = graph_prefs.allowPanning orelse true,
            } else .{},
            .definitionsPanel = if (prefs.definitionsPanel) |def_panel_prefs| .{
                .orientation = def_panel_prefs.orientation orelse .left,
                .visible = def_panel_prefs.visible orelse true,
            } else .{},
            .topbar = if (prefs.topbar) |topbar_prefs| .{
                .visible = topbar_prefs.visible orelse true,
            } else .{},
        } else .{},
    };
}

const gpa = App.gpa;
const graphl = @import("graphl_core");
// FIXME: move to util package
const IntArrayHashMap = @import("graphl_core").IntArrayHashMap;
const helpers = @import("graphl_core").helpers;
const sourceToGraph = @import("./source_to_graph.zig").sourceToGraph;

const App = @import("./app.zig");
const std = @import("std");
const builtin = @import("builtin");
