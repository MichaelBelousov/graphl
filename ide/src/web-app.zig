// FIXME: avoid globals/module-level-state until the consumer level
var app: App = undefined;
var init_opts: App.InitOptions = .{
    .transfer_buffer = transfer_buffer[0..],
};


// TODO: just import json_format namespace
pub const json_format = @import("./json-format.zig");
pub const MenuOptionJson = @import("./json-format.zig").MenuOptionJson;
const PtJson = @import("./json-format.zig").PtJson;
pub const InputInitStateJson = App.InputInitState;
pub const NodeInitStateJson = @import("./json-format.zig").NodeInitStateJson;
pub const GraphInitStateJson = @import("./json-format.zig").GraphInitStateJson;
pub const GraphsInitStateJson = @import("./json-format.zig").GraphInitStateJson;
pub const BasicMutNodeDescJson = @import("./json-format.zig").BasicMutNodeDescJson;
pub const UserFuncJson = @import("./json-format.zig").UserFuncJson;
pub const InitOptsJson = @import("./json-format.zig").InitOptsJson;
const dvui = @import("dvui");


pub fn init(window: *dvui.Window) !void {
    if (init_opts.result_buffer == null) {
        @panic("setInitOpts hasn't been called before init!");
    }
    init_opts.window = window;
    try App.init(&app, init_opts);
}

pub fn deinit() void {
    app.deinit();
}

pub fn frame() !void {
    try app.frame();
}

// FIXME: just use the transfer buffer again
export var result_buffer = std.mem.zeroes([4096]u8);
export var transfer_buffer: [16384]u8 = undefined;
export const transfer_buffer_len: usize = transfer_buffer.len;

export fn onReceiveLoadedSource(in_ptr: ?[*]const u8, len: usize) void {
    const src = (in_ptr orelse return)[0..len];

    app.onReceiveLoadedSource(src) catch |err| {
        std.log.err("sourceToGraph error: {}", .{err});
        return;
    };
}

// TODO: maybe rename to returnSlice?
extern fn onReceiveSlice(ptr: ?[*]const u8, len: usize) void;

/// returns null if failure
export fn compileToWasm() void {
    const wasm = app.compileToWasm() catch |e| {
        std.log.err("compileToWasm error {}", .{e});
        return;
    };
    defer gpa.free(wasm);

    onReceiveSlice(wasm.ptr, wasm.len);
}

export fn compileToGraphlt() void {
    const graphlt = app.compileToGraphlt() catch |e| {
        std.log.err("compileToGraphlt error {}", .{e});
        return;
    };
    defer gpa.free(graphlt);

    onReceiveSlice(graphlt.ptr, graphlt.len);
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

fn _setInitOpts(in_json: []const u8) !void {
    const json = try gpa.dupe(u8, in_json);
    var arena = std.heap.ArenaAllocator.init(gpa);
    // NOTE: leaks on success, fix when switching from using globals
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

    const menus: []const App.MenuOption = if (init_opts_json.menus) |m| try json_format.convertMenus(gpa, m, onMenuClick) else &.{};
    // FIXME: need to recursively free menus! submenus leak right now
    errdefer if (init_opts_json.menus != null) gpa.free(menus);

    var graphs: std.StringHashMapUnmanaged(App.GraphInitState) = if (init_opts_json.graphs) |g| try json_format.convertGraphs(gpa, g) else .{};
    errdefer graphs.deinit(gpa);

    const user_funcs: []const graphl.compiler.UserFunc = if (init_opts_json.userFuncs) |uf| try json_format.convertUserFuncs(gpa, uf) else &.{};
    errdefer if (init_opts_json.userFuncs != null) user_funcs.deinit(gpa);

    init_opts = .{
        .result_buffer = &result_buffer,
        .transfer_buffer = &transfer_buffer,
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
        .window = init_opts.window,
    };
}

export fn pasteText(clipboard_ptr: [*]const u8, clipboard_len: usize) void {
    app.pasteText(clipboard_ptr[0..clipboard_len]);
}

// TODO: replace with save via grappl
export fn getGraphsJson() void {
    const json = app.getGraphsJson() catch |err| {
        std.log.err("getGraphsJson error: {}", .{err});
        return;
    };
    defer gpa.free(json);
    onReceiveSlice(json.ptr, json.len);
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
