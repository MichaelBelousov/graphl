// FIXME
var app: App = .{};
var init_opts: App.InitOptions = .{
    .result_buffer = &result_buffer,
};

var user_funcs: std.ArrayListUnmanaged(graphl.compiler.UserFunc) = .{};

pub fn init() !void {
    init_opts.user_funcs = user_funcs.items;
    try App.init(&app, init_opts);
}

pub fn deinit() void {
    app.deinit();
    user_funcs.deinit(gpa);
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

export fn setOpt_preferences_graph_origin(x: f32, y: f32) bool {
    init_opts.preferences.graph.origin = .{ .x = x, .y = y };
    return true;
}

export fn setOpt_preferences_graph_scale(val: f32) bool {
    init_opts.preferences.graph.scale = val;
    return true;
}

export fn setOpt_preferences_graph_scrollBarsVisible(val: bool) bool {
    init_opts.preferences.graph.scrollBarsVisible = val;
    return true;
}

export fn setOpt_preferences_graph_allowPanning(val: bool) bool {
    init_opts.preferences.graph.allowPanning = val;
    return true;
}

// FIXME: move these to web.zig?
export fn setOpt_preferences_definitionsPanel_orientation(val: App.Orientation) bool {
    init_opts.preferences.definitionsPanel.orientation = val;
    return true;
}

export fn setOpt_preferences_definitionsPanel_visible(val: bool) bool {
    init_opts.preferences.definitionsPanel.visible = val;
    return true;
}

export fn setOpt_preferences_topbar_visible(val: bool) bool {
    init_opts.preferences.topbar.visible = val;
    return true;
}

export fn setInitState_graphs_notRemovable(
    graph_name_ptr: [*]const u8,
    graph_name_len: usize,
    val: bool,
) bool {
    const graph_name = gpa.dupe(u8, graph_name_ptr[0..graph_name_len]) catch |err| {
        std.log.err("failed to alloc graph name '{s}', error={}", .{ graph_name_ptr[0..graph_name_len], err });
        return false;
    };
    const graph = _: {
        const get_or_put = init_opts.graphs.getOrPut(gpa, graph_name) catch |err| {
            std.log.err("failed to put graph '{s}', error={}", .{ graph_name, err });
            return false;
        };
        if (!get_or_put.found_existing) {
            get_or_put.value_ptr.* = .{};
        }
        break :_ get_or_put.value_ptr;
    };

    graph.notRemovable = val;

    return true;
}

export fn setInitState_graphs_nodes_type(
    graph_name_ptr: [*]const u8,
    graph_name_len: usize,
    node_index: usize,
    node_id: usize,
    type_ptr: [*]const u8,
    type_len: usize,
) bool {
    const type_ = gpa.dupe(u8, type_ptr[0..type_len]) catch |err| {
        std.log.err("failed to put dupe type name error={}", .{err});
        return false;
    };

    const node = _setInitState_getNode(graph_name_ptr, graph_name_len, node_index, node_id) catch {
        return false;
    };

    node.type_ = type_;

    return true;
}

export fn setInitState_graphs_nodes_pos(
    graph_name_ptr: [*]const u8,
    graph_name_len: usize,
    node_index: usize,
    node_id: usize,
    pos_x: f32,
    pos_y: f32,
) bool {
    const node = _setInitState_getNode(graph_name_ptr, graph_name_len, node_index, node_id) catch {
        return false;
    };

    node.position = .{ .x = pos_x, .y = pos_y };

    return true;
}

fn _setInitState_getNode(
    graph_name_ptr: [*]const u8,
    graph_name_len: usize,
    node_index: usize,
    node_id: usize,
) !*App.NodeInitState {
    const graph_name = try gpa.dupe(u8, graph_name_ptr[0..graph_name_len]);

    const graph = _: {
        const get_or_put = try init_opts.graphs.getOrPut(gpa, graph_name);
        if (!get_or_put.found_existing) {
            get_or_put.value_ptr.* = .{};
        }
        break :_ get_or_put.value_ptr;
    };

    if (node_index >= graph.nodes.items.len) {
        const new_elems = try graph.nodes.addManyAsSlice(gpa, node_index + 1 - graph.nodes.items.len);
        // set to 0 since it's a checked illegal entry, and we can use it to tell if this node has been set yet
        for (new_elems) |*new_elem| new_elem.id = 0;
    }

    const node = &graph.nodes.items[node_index];
    if (node.id == 0) {
        node.* = .{
            .id = node_id,
            .type_ = "<UNSET_TYPE>",
            .inputs = .{},
        };
    }

    return node;
}

fn _setInitState_getInput(
    graph_name_ptr: [*]const u8,
    graph_name_len: usize,
    node_index: usize,
    node_id: usize,
    input_id: u16,
) !*App.InputInitState {
    const node = try _setInitState_getNode(graph_name_ptr, graph_name_len, node_index, node_id);
    const input = _: {
        // FIXME: there's probably an API for this type of action
        const get_or_put = try node.inputs.getOrPut(gpa, input_id);
        break :_ get_or_put.value_ptr;
    };
    return input;
}

export fn setInitState_graphs_nodes_input_int(graph_name_ptr: [*]const u8, graph_name_len: usize, node_index: usize, node_id: usize, input_id: u16, value: i64) bool {
    const input = _setInitState_getInput(graph_name_ptr, graph_name_len, node_index, node_id, input_id) catch {
        return false;
    };
    input.* = .{ .int = value };
    return true;
}

export fn setInitState_graphs_nodes_input_bool(graph_name_ptr: [*]const u8, graph_name_len: usize, node_index: usize, node_id: usize, input_id: u16, value: bool) bool {
    const input = _setInitState_getInput(graph_name_ptr, graph_name_len, node_index, node_id, input_id) catch {
        return false;
    };
    input.* = .{ .bool = value };
    return true;
}

export fn setInitState_graphs_nodes_input_float(graph_name_ptr: [*]const u8, graph_name_len: usize, node_index: usize, node_id: usize, input_id: u16, value: f64) bool {
    const input = _setInitState_getInput(graph_name_ptr, graph_name_len, node_index, node_id, input_id) catch {
        return false;
    };
    input.* = .{ .float = value };
    return true;
}

export fn setInitState_graphs_nodes_input_string(graph_name_ptr: [*]const u8, graph_name_len: usize, node_index: usize, node_id: usize, input_id: u16, value_ptr: [*]const u8, value_len: usize) bool {
    const input = _setInitState_getInput(graph_name_ptr, graph_name_len, node_index, node_id, input_id) catch {
        return false;
    };
    const value = gpa.dupe(u8, value_ptr[0..value_len]) catch {
        return false;
    };
    input.* = .{ .string = value };
    return true;
}

export fn setInitState_graphs_nodes_input_symbol(graph_name_ptr: [*]const u8, graph_name_len: usize, node_index: usize, node_id: usize, input_id: u16, value_ptr: [*]const u8, value_len: usize) bool {
    const input = _setInitState_getInput(graph_name_ptr, graph_name_len, node_index, node_id, input_id) catch {
        return false;
    };
    const value = gpa.dupe(u8, value_ptr[0..value_len]) catch {
        return false;
    };
    input.* = .{ .symbol = value };
    return true;
}

export fn setInitState_graphs_nodes_input_pin(graph_name_ptr: [*]const u8, graph_name_len: usize, node_index: usize, node_id: usize, input_id: u16, target_id: usize, out_pin: usize) bool {
    const input = _setInitState_getInput(graph_name_ptr, graph_name_len, node_index, node_id, input_id) catch {
        return false;
    };
    input.* = .{
        .node = .{ .id = target_id, .out_pin = out_pin },
    };
    return true;
}

export fn createUserFunc(name_len: u32, input_count: u32, output_count: u32) usize {
    const name = graphl_real_init_buff[0..name_len];
    return _createUserFunc(name, input_count, output_count) catch unreachable;
}

export fn addUserFuncInput(func_id: usize, index: u32, name_len: u32, input_type: u32) void {
    const name = graphl_real_init_buff[0..name_len];
    return _addUserFuncInput(func_id, index, name, @enumFromInt(input_type)) catch unreachable;
}

export fn addUserFuncOutput(func_id: usize, index: u32, name_len: u32, output_type: u32) void {
    const name = graphl_real_init_buff[0..name_len];
    return _addUserFuncOutput(func_id, index, name, @enumFromInt(output_type)) catch unreachable;
}

pub fn _createUserFunc(name: []const u8, input_count: u32, output_count: u32) !usize {
    const new_func = try user_funcs.addOne(gpa);
    new_func.* = .{
        .id = user_funcs.items.len - 1,
        .node = .{
            .name = try gpa.dupe(u8, name),
            .hidden = false,
            .inputs = try gpa.alloc(helpers.Pin, input_count + 1), // an extra is inserted for exec
            .outputs = try gpa.alloc(helpers.Pin, output_count + 1), // an extra is inserted for exec
        },
    };

    new_func.node.inputs[0] = helpers.Pin{
        .name = "exec",
        .kind = .{ .primitive = .exec },
    };

    new_func.node.outputs[0] = helpers.Pin{
        .name = "",
        .kind = .{ .primitive = .exec },
    };

    return new_func.id;
}

pub fn _addUserFuncInput(func_id: usize, index: u32, name: []const u8, input_type_tag: App.UserFuncTypes) !void {
    const input_type = switch (input_type_tag) {
        .i32_ => graphl.primitive_types.i32_,
        .i64_ => graphl.primitive_types.i64_,
        .f32_ => graphl.primitive_types.f32_,
        .f64_ => graphl.primitive_types.f64_,
        .string => graphl.primitive_types.string,
        .code => graphl.primitive_types.code,
        .bool => graphl.primitive_types.bool_,
    };

    const func = &user_funcs.items[func_id].node;

    // skip the exec index
    func.inputs[index + 1] = helpers.Pin{
        .name = try gpa.dupe(u8, name),
        .kind = .{ .primitive = .{ .value = input_type } },
    };
}

pub fn _addUserFuncOutput(func_id: usize, index: u32, name: []const u8, output_type_tag: App.UserFuncTypes) !void {
    const output_type = switch (output_type_tag) {
        .i32_ => graphl.primitive_types.i32_,
        .i64_ => graphl.primitive_types.i64_,
        .f32_ => graphl.primitive_types.f32_,
        .f64_ => graphl.primitive_types.f64_,
        .string => graphl.primitive_types.string,
        .code => graphl.primitive_types.code,
        .bool => graphl.primitive_types.bool_,
    };

    const func = &user_funcs.items[func_id].node;

    // skip the exec index
    func.outputs[index + 1] = helpers.Pin{
        .name = try gpa.dupe(u8, name),
        .kind = .{ .primitive = .{ .value = output_type } },
    };
}

const gpa = App.gpa;
const graphl = @import("grappl_core");
const helpers = @import("grappl_core").helpers;
const sourceToGraph = @import("./source_to_graph.zig").sourceToGraph;

const App = @import("./app.zig");
const std = @import("std");
const builtin = @import("builtin");
