//! Copyright 2024, Michael Belouso
//!

// TODO: rename this file to App.zig
const App = @This();

const std = @import("std");
const builtin = @import("builtin");

const dvui = @import("dvui");
const entypo = @import("dvui").entypo;
const Rect = dvui.Rect;
const dvui_extra = @import("./dvui-extra.zig");

const grappl = @import("grappl_core");
const compiler = grappl.compiler;
const SexpParser = @import("grappl_core").SexpParser;
const Sexp = @import("grappl_core").Sexp;
const helpers = @import("grappl_core").helpers;
const sourceToGraph = @import("./source_to_graph.zig").sourceToGraph;

const MAX_FUNC_NAME = 256;

// FIXME: these need to have the App instance as an argument
extern fn onExportCurrentSource(ptr: ?[*]const u8, len: usize) void;
extern fn onExportCompiled(ptr: ?[*]const u8, len: usize) void;
extern fn onRequestLoadSource() void;
extern fn onClickReportIssue() void;
extern fn runCurrentWat(ptr: ?[*]const u8, len: usize) void;

//const gpa = gpa_instance.allocator();
var gpa_instance = std.heap.GeneralPurposeAllocator(.{
    //.retain_metadata = true,
    //.never_unmap = true,
    //.verbose_log = true,
}){};

pub const gpa = if (builtin.cpu.arch.isWasm())
    std.heap.wasm_allocator
else
    gpa_instance.allocator();

pub const Graph = struct {
    index: u16,

    name: []u8,

    call_basic_desc: grappl.helpers.BasicMutNodeDesc,
    call_desc: *grappl.NodeDesc,

    // FIXME: singly-linked list?
    param_getters: std.ArrayListUnmanaged(*grappl.helpers.BasicMutNodeDesc) = .{},
    param_setters: std.ArrayListUnmanaged(*grappl.helpers.BasicMutNodeDesc) = .{},

    grappl_graph: grappl.GraphBuilder,
    // FIXME: merge with visual graph
    visual_graph: VisualGraph,

    // FIXME: why is this separate from self.grappl_graph.env
    env: grappl.Env,
    app: *App,

    pub fn env(self: @This()) *const grappl.Env {
        return self.grappl_graph.env;
    }

    /// NOTE: copies passed in name
    pub fn init(app: *App, index: u16, in_name: []const u8) !@This() {
        var result: @This() = undefined;
        try result.initInPlace(app, index, in_name);
        return result;
    }

    /// NOTE: copies passed in name
    pub fn initInPlace(self: *@This(), app: *App, index: u16, in_name: []const u8) !void {
        self.env = app.shared_env.spawn();

        const grappl_graph = try grappl.GraphBuilder.init(gpa, &self.env);

        const name_copy = try gpa.dupe(u8, in_name);

        // NOTE: does this only work because of return value optimization?
        self.* = @This(){
            .app = app,
            .name = name_copy,
            .index = index,
            .grappl_graph = grappl_graph,
            .visual_graph = undefined,
            .env = self.env,
            .call_basic_desc = undefined,
            .call_desc = undefined,
        };

        self.call_basic_desc = helpers.BasicMutNodeDesc{
            .name = name_copy,
            .inputs = grappl_graph.entry_node_basic_desc.outputs,
            .outputs = grappl_graph.result_node_basic_desc.inputs,
        };

        // FIXME: remove node on err
        self.call_desc = try app.shared_env.addNode(
            gpa,
            helpers.basicMutableNode(&self.call_basic_desc),
        );

        self.visual_graph = VisualGraph{ .graph = &self.grappl_graph };

        std.debug.assert(self.grappl_graph.nodes.map.getPtr(0).?.id == self.grappl_graph.entry_id);

        try self.visual_graph.node_data.put(gpa, 0, .{
            .position = dvui.Point{ .x = 200, .y = 200 },
            .position_override = dvui.Point{ .x = 200, .y = 200 },
        });
    }

    pub fn deinit(self: *@This()) void {
        std.debug.assert(self.app.shared_env._nodes.remove(self.call_basic_desc.name));

        for (self.param_getters.items) |param_getter| {
            // FIXME: these should be easier to manage the memory of!
            gpa.free(param_getter.outputs[0].name);
            gpa.free(param_getter.name);
            gpa.free(param_getter.inputs);
            gpa.free(param_getter.outputs);
            gpa.destroy(param_getter);
        }
        self.param_getters.deinit(gpa);

        for (self.param_setters.items) |param_setter| {
            gpa.free(param_setter.name);
            gpa.free(param_setter.inputs);
            gpa.free(param_setter.outputs);
            gpa.destroy(param_setter);
        }
        self.param_setters.deinit(gpa);

        self.visual_graph.deinit(gpa);
        self.grappl_graph.deinit(gpa);
        gpa.free(self.name);
        self.env.deinit(gpa);
    }

    pub fn addNode(self: *@This(), alloc: std.mem.Allocator, kind: []const u8, is_entry: bool, force_node_id: ?grappl.NodeId, diag: ?*grappl.GraphBuilder.Diagnostic, pos: dvui.Point) !grappl.NodeId {
        return self.visual_graph.addNode(alloc, kind, is_entry, force_node_id, diag, pos);
    }

    pub fn removeNode(self: *@This(), node_id: grappl.NodeId) !bool {
        return self.visual_graph.removeNode(node_id);
    }

    pub fn addEdge(self: *@This(), a: std.mem.Allocator, start_id: grappl.NodeId, start_index: u16, end_id: grappl.NodeId, end_index: u16, end_subindex: u16) !void {
        return self.visual_graph.addEdge(a, start_id, start_index, end_id, end_index, end_subindex);
    }

    pub fn removeEdge(self: *@This(), start_id: grappl.NodeId, start_index: u16, end_id: grappl.NodeId, end_index: u16, end_subindex: u16) !void {
        return self.visual_graph.removeEdge(start_id, start_index, end_id, end_index, end_subindex);
    }

    pub fn addLiteralInput(self: @This(), node_id: grappl.NodeId, pin_index: u16, subpin_index: u16, value: grappl.Value) !void {
        return self.visual_graph.addLiteralInput(node_id, pin_index, subpin_index, value);
    }

    pub fn removeOutputLinks(self: *@This(), node_id: grappl.NodeId, output_index: u16) !void {
        return self.grappl_graph.removeOutputLinks(node_id, output_index);
    }
};

/// uses gpa, deinit the result with gpa
pub fn combineGraphs(
    self: *const @This(),
) !Sexp {
    // FIXME: use an arena!
    // not currently possible because grappl_graph.compile allocates permanent memory
    // for incremental compilation... the graph should take a separate allocator for
    // such memory, or use its own system allocator
    var result = Sexp.newModule(gpa);
    try result.value.module.ensureTotalCapacity(@intCast(self.next_graph_index * 2));

    var maybe_cursor = self.graphs.first;
    while (maybe_cursor) |cursor| : (maybe_cursor = cursor.next) {
        var diagnostic = grappl.GraphBuilder.Diagnostics.init();
        var graph_sexp = cursor.data.grappl_graph.compile(gpa, cursor.data.name, &diagnostic) catch |e| {
            std.log.err("diagnostic: {}\n", .{diagnostic.contextualize(&cursor.data.grappl_graph)});
            return e;
        };
        defer graph_sexp.value.module.clearAndFree();
        std.debug.assert(graph_sexp.value == .module);
        try result.value.module.appendSlice(graph_sexp.value.module.items);
    }

    return result;
}

// TODO: take an allocator once compiling allocation is fixed
fn combineGraphsText(
    self: *@This(),
) !std.ArrayList(u8) {
    var bytes = std.ArrayList(u8).init(gpa);

    var maybe_cursor = self.graphs.first;
    while (maybe_cursor) |cursor| : ({
        if (cursor.next != null)
            try bytes.append('\n');
        maybe_cursor = cursor.next;
    }) {
        var diagnostic = grappl.GraphBuilder.Diagnostics.init();
        const sexp = cursor.data.grappl_graph.compile(gpa, cursor.data.name, &diagnostic) catch |e| {
            std.log.err("diagnostic: {}\n", .{diagnostic.contextualize(&cursor.data.grappl_graph)});
            return e;
        };
        defer sexp.deinit(gpa);

        _ = try sexp.write(bytes.writer());
    }

    return bytes;
}

fn exportCurrentSource(self: *@This()) !void {
    var bytes = try combineGraphsText(self);
    defer bytes.deinit();

    onExportCurrentSource(bytes.items.ptr, bytes.items.len);
}

fn setCurrentGraphByIndex(self: *@This(), index: u16) !void {
    if (index == self.current_graph.index)
        return;

    var maybe_cursor = self.graphs.first;
    var i = index;
    while (maybe_cursor) |cursor| : ({
        maybe_cursor = cursor.next;
        i -= 1;
    }) {
        if (i == 0) {
            self.current_graph = &cursor.data;
            return;
        }
    }
    return error.RangeError;
}

pub fn addGraph(self: *@This(), name: []const u8, set_as_current: bool) !*Graph {
    const graph_index = self.next_graph_index;
    self.next_graph_index += 1;
    errdefer self.next_graph_index -= 1;

    var new_graph = try gpa.create(std.SinglyLinkedList(Graph).Node);

    new_graph.* = .{ .data = undefined };
    try new_graph.data.initInPlace(self, graph_index, name);

    if (set_as_current)
        self.current_graph = &new_graph.data;

    if (self.graphs.first == null) {
        self.graphs.prepend(new_graph);
    } else {
        // FIXME: why not prepend?
        var maybe_cursor = self.graphs.first;
        while (maybe_cursor) |cursor| : (maybe_cursor = cursor.next) {
            if (cursor.next == null) {
                cursor.insertAfter(new_graph);
                break;
            }
        }
    }

    return &new_graph.data;
}

// FIXME: should this be undefined?
shared_env: grappl.Env = undefined,

context_menu_widget_id: ?u32 = null,
node_menu_filter: ?Socket = null,

// the start of an attempt to drag an edge out of a socket
edge_drag_start: ?struct {
    pt: dvui.Point,
    socket: Socket,
} = null,

prev_drag_state: ?dvui.Point = null,

edge_drag_end: ?Socket = null,

// NOTE: must be singly linked list because Graph contains an internal pointer and cannot be moved!
graphs: std.SinglyLinkedList(Graph) = .{},
current_graph: *Graph = undefined,
next_graph_index: u16 = 0,

// FIXME: for wasm
//pub var user_funcs = UserFuncList{};
//var next_user_func: usize = 0;

init_opts: InitOptions = .{},
user_funcs: UserFuncList = .{},

pub const UserFuncList = std.SinglyLinkedList(compiler.UserFunc);

pub const MenuOption = struct {
    name: []const u8,
    on_click: ?*const fn (ctx: ?*anyopaque) void = null,
    submenus: []const MenuOption = &.{},
};

pub const InitOptions = struct {
    menus: []const MenuOption = &.{},
    result_buffer: ?[]u8 = null,
    context: ?*anyopaque = null,
    graphs: std.StringHashMapUnmanaged(struct {
        notRemovable: bool = false,
        nodes: std.ArrayListUnmanaged(NodeInitState) = .{},
    }) = .{},
    user_funcs: []const compiler.UserFunc = &.{},
    preferences: struct {
        graph: struct {
            origin: ?dvui.Point = null,
            scale: ?f32 = null,
            scrollBarsVisible: ?bool = false,
            allowPanning: bool = true,
        } = .{},
        definitionsPanel: struct {
            orientation: Orientation = .left,
            visible: bool = true,
        } = .{},
        topbar: struct {
            visible: bool = true,
        } = .{},
    } = .{},
};

// FIXME: consider moving options and initState to a separate file

pub const Orientation = enum(u32) {
    left = 0,
    right = 1,
};

// FIXME: generate this object and all of the setter functions in the build
// NOTE: must correlate to WebBackend.d.ts
var options: struct {} = .{};

pub const InputInitState = union(enum) {
    node: struct { id: usize, out_pin: usize },
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    symbol: []const u8,
};

pub const NodeInitState = struct {
    id: usize,
    /// type of node "+"
    type_: []const u8,
    inputs: std.AutoHashMapUnmanaged(u16, InputInitState),
    position: ?dvui.Point = null,
};

// FIXME: keep in sync with typescript automatically
pub const UserFuncTypes = enum(u32) {
    i32_ = 0,
    i64_ = 1,
    f32_ = 2,
    f64_ = 3,
    string = 4,
    code = 5,
    bool = 6,
};

pub fn init(self: *@This(), in_opts: InitOptions) !void {
    self.* = .{
        .init_opts = in_opts,
        .shared_env = try grappl.Env.initDefault(gpa),
        .user_funcs = UserFuncList{},
    };

    for (in_opts.user_funcs) |user_func| {
        const node = try gpa.create(UserFuncList.Node);
        node.* = .{ .data = user_func };
        self.user_funcs.prepend(node);
        _ = try self.shared_env.addNode(gpa, helpers.basicMutableNode(&node.data.node));
    }

    // TODO:
    if (in_opts.graphs.count() > 0) {
        var graph_iter = in_opts.graphs.iterator();
        while (graph_iter.next()) |entry| {
            const graph_name = entry.key_ptr;
            const graph_desc = entry.value_ptr;
            // FIXME: must I dupe this?
            const graph = try addGraph(self, graph_name.*, true);
            for (graph_desc.nodes.items) |node_desc| {
                const node_id: grappl.NodeId = @intCast(node_desc.id);
                _ = try graph.addNode(gpa, node_desc.type_, false, node_id, null, .{});
                if (node_desc.position) |pos| {
                    const node = graph.visual_graph.node_data.getPtr(node_id) orelse unreachable;
                    node.position_override = pos;
                }
                var input_iter = node_desc.inputs.iterator();
                while (input_iter.next()) |input_entry| {
                    const input_id = input_entry.key_ptr.*;
                    const input_desc = input_entry.value_ptr;
                    switch (input_desc.*) {
                        .node => |v| {
                            try graph.addEdge(gpa, @intCast(v.id), @intCast(v.out_pin), node_id, input_id, 0);
                        },
                        .int => |v| {
                            try graph.addLiteralInput(node_id, input_id, 0, .{ .int = v });
                        },
                        .float => |v| {
                            try graph.addLiteralInput(node_id, input_id, 0, .{ .float = v });
                        },
                        .bool => |v| {
                            try graph.addLiteralInput(node_id, input_id, 0, .{ .bool = v });
                        },
                        .string => |v| {
                            try graph.addLiteralInput(node_id, input_id, 0, .{ .string = v });
                        },
                        .symbol => |v| {
                            try graph.addLiteralInput(node_id, input_id, 0, .{ .symbol = v });
                        },
                    }
                }
            }
            try graph.visual_graph.formatGraphNaive(gpa);
        }
    } else {
        _ = try addGraph(self, "main", true);
    }
}

pub fn runCurrentGraphs(self: *const @This()) !void {
    const sexp = try combineGraphs(self);
    defer sexp.deinit(gpa);

    if (builtin.mode == .Debug) {
        var bytes = std.ArrayList(u8).init(gpa);
        defer bytes.deinit();
        _ = try sexp.write(bytes.writer());
        std.log.info("graph '{s}':\n{s}", .{ self.current_graph.name, bytes.items });
    }

    var diagnostic = compiler.Diagnostic.init();

    if (compiler.compile(gpa, &sexp, &self.shared_env, &self.user_funcs, &diagnostic)) |module| {
        std.log.info("compile_result:\n{s}", .{module});
        runCurrentWat(module.ptr, module.len);
        gpa.free(module);
    } else |err| {
        std.log.err("compile_error={any}", .{err});
    }
}

fn exportCurrentCompiled(self: *const @This()) !void {
    const sexp = try combineGraphs(self);
    defer sexp.deinit(gpa);

    if (builtin.mode == .Debug) {
        var bytes = std.ArrayList(u8).init(gpa);
        defer bytes.deinit();
        _ = try sexp.write(bytes.writer());
        std.log.info("graph '{s}':\n{s}", .{ self.current_graph.name, bytes.items });
    }

    var diagnostic = compiler.Diagnostic.init();

    if (compiler.compile(gpa, &sexp, &self.shared_env, &self.user_funcs, &diagnostic)) |module| {
        std.log.info("compile_result:\n{s}", .{module});
        onExportCompiled(module.ptr, module.len);
        gpa.free(module);
    } else |err| {
        std.log.err("compile_error={any}", .{err});
    }
}

pub fn deinit(self: *@This()) void {
    while (self.graphs.popFirst()) |cursor| {
        cursor.data.deinit();
        gpa.destroy(cursor);
    }
    self.graphs.first = null;

    self.shared_env.deinit(gpa);

    while (self.user_funcs.popFirst()) |cursor| {
        gpa.free(cursor.data.node.name);
        for (cursor.data.node.inputs[1..]) |input| gpa.free(input.name);
        gpa.free(cursor.data.node.inputs);
        for (cursor.data.node.outputs[1..]) |output| gpa.free(output.name);
        gpa.free(cursor.data.node.outputs);
        gpa.destroy(cursor);
    }

    // FIXME: this breaks in tests
    //_ = gpa_instance.deinit();
}

const SocketType = enum(u1) { input, output };

const Socket = struct {
    node_id: grappl.NodeId,
    kind: SocketType,
    index: u16,
};

pub const NodeAdder = struct {
    pub fn validSocketIndex(
        node_desc: *const grappl.NodeDesc,
        create_from_socket: Socket,
        create_from_type: grappl.PrimitivePin,
    ) !?u16 {
        var valid_socket_index: ?u16 = null;

        const pins = switch (create_from_socket.kind) {
            .input => node_desc.getOutputs(),
            .output => node_desc.getInputs(),
        };

        if (pins.len > std.math.maxInt(u16))
            return error.TooManyPins;

        for (pins, 0..) |pin_desc, j| {
            if (std.meta.eql(pin_desc.asPrimitivePin(), create_from_type)
            //
            or std.meta.eql(pin_desc.asPrimitivePin(), helpers.PrimitivePin{ .value = helpers.primitive_types.code })
            //
            ) {
                valid_socket_index = @intCast(j);
                break;
            }
        }

        return valid_socket_index;
    }

    pub fn addNode(
        app: *App,
        node_name: []const u8,
        _maybe_create_from: ?Socket,
        _pt_in_graph: dvui.Point,
        valid_socket_index: ?u16,
    ) !u32 {
        // TODO: use diagnostic
        const new_node_id = try app.current_graph.addNode(gpa, node_name, false, null, null, _pt_in_graph);

        if (_maybe_create_from) |create_from| {
            switch (create_from.kind) {
                .input => {
                    try app.current_graph.addEdge(gpa, new_node_id, valid_socket_index orelse 0, create_from.node_id, create_from.index, 0);
                },
                .output => {
                    try app.current_graph.addEdge(gpa, create_from.node_id, create_from.index, new_node_id, valid_socket_index orelse 0, 0);
                },
            }
        }

        return new_node_id;
    }
};

fn renderAddNodeMenu(self: *@This(), pt: dvui.Point, pt_in_graph: dvui.Point, maybe_create_from: ?Socket) !void {
    // TODO: handle defocus event
    var fw = try dvui.floatingMenu(@src(), Rect.fromPoint(pt), .{});
    defer fw.deinit();

    const search_input = _: {
        const text_result = try dvui.textEntry(@src(), .{}, .{});
        defer text_result.deinit();
        // FIXME: this is very lax...
        if (dvui.firstFrame(text_result.data().id)) {
            dvui.focusWidget(text_result.data().id, null, null);
        }
        // TODO: don't dupe this memory! use a dynamic buffer instead
        break :_ text_result.getText();
    };

    const maybe_create_from_type: ?grappl.PrimitivePin = if (maybe_create_from) |create_from| _: {
        const node = self.current_graph.grappl_graph.nodes.map.get(create_from.node_id) orelse unreachable;
        const pins = switch (create_from.kind) {
            .output => node.desc().getOutputs(),
            .input => node.desc().getInputs(),
        };
        const pin_type = pins[create_from.index].asPrimitivePin();

        // don't filter on a type if we're creating from a code socket, that can take anything
        if (std.meta.eql(pin_type, grappl.PrimitivePin{ .value = grappl.primitive_types.code }))
            break :_ null;

        break :_ pin_type;
    } else null;

    const bindings_infos = &.{
        .{ .data = &self.current_graph.grappl_graph.locals, .display = "Locals" },
    };

    inline for (bindings_infos, 0..) |bindings_info, i| {
        const bindings = bindings_info.data;

        // TODO: don't show "Get Locals >" if none of them match the search
        if (bindings.items.len > 0) {
            if (maybe_create_from == null or maybe_create_from.?.kind == .input) {
                if (try dvui.menuItemLabel(@src(), "Get " ++ bindings_info.display ++ " >", .{ .submenu = true }, .{ .expand = .horizontal, .id_extra = i })) |r| {
                    var subfw = try dvui.floatingMenu(@src(), Rect.fromPoint(dvui.Point{ .x = r.x + r.w, .y = r.y }), .{});
                    defer subfw.deinit();

                    for (bindings.items, 0..) |binding, j| {
                        const id_extra = (j << 8) | i;

                        if (maybe_create_from_type != null and !std.meta.eql(maybe_create_from_type.?, grappl.PrimitivePin{ .value = binding.type_ })) {
                            continue;
                        }

                        if (search_input.len != 0) {
                            const matches_search = std.ascii.indexOfIgnoreCase(binding.name, search_input) != null;
                            if (!matches_search) continue;
                        }

                        var buf: [MAX_FUNC_NAME]u8 = undefined;
                        const label = try std.fmt.bufPrint(&buf, "Get {s}", .{binding.name});

                        if (try dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal, .id_extra = id_extra }) != null) {
                            const getter_name = try std.fmt.bufPrint(&buf, "get_{s}", .{binding.name});
                            _ = try NodeAdder.addNode(self, getter_name, maybe_create_from, pt_in_graph, 0);
                            subfw.close();
                        }
                    }
                }
            }

            if (try dvui.menuItemLabel(@src(), "Set " ++ bindings_info.display ++ " >", .{ .submenu = true }, .{ .expand = .horizontal, .id_extra = i })) |r| {
                var subfw = try dvui.floatingMenu(@src(), Rect.fromPoint(dvui.Point{ .x = r.x + r.w, .y = r.y }), .{});
                defer subfw.deinit();

                for (bindings.items, 0..) |binding, j| {
                    const id_extra = (j << 8) | i;
                    var buf: [MAX_FUNC_NAME]u8 = undefined;
                    const name = try std.fmt.bufPrint(&buf, "set_{s}", .{binding.name});
                    const node_desc = self.current_graph.env.getNode(name) orelse {
                        std.log.err("couldn't get node by binding: '{s}'", .{binding.name});
                        unreachable;
                    };

                    var valid_socket_index: ?u16 = null;
                    if (maybe_create_from_type) |create_from_type| {
                        valid_socket_index = try NodeAdder.validSocketIndex(node_desc, maybe_create_from.?, create_from_type);
                        if (valid_socket_index == null)
                            continue;
                    }

                    if (search_input.len != 0) {
                        const matches_search = std.ascii.indexOfIgnoreCase(binding.name, search_input) != null;
                        if (!matches_search) continue;
                    }

                    var label_buf: [MAX_FUNC_NAME]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buf, "Set {s}", .{binding.name});

                    if (try dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal, .id_extra = id_extra }) != null) {
                        _ = try NodeAdder.addNode(self, name, maybe_create_from, pt_in_graph, valid_socket_index);
                        subfw.close();
                    }
                }
            }
        }
    }

    if (self.current_graph.grappl_graph.entry_node_basic_desc.outputs.len > 1) {
        if (maybe_create_from == null or maybe_create_from.?.kind == .input) {
            if (try dvui.menuItemLabel(@src(), "Get Params >", .{ .submenu = true }, .{ .expand = .horizontal })) |r| {
                var subfw = try dvui.floatingMenu(@src(), Rect.fromPoint(dvui.Point{ .x = r.x + r.w, .y = r.y }), .{});
                defer subfw.deinit();

                for (self.current_graph.grappl_graph.entry_node_basic_desc.outputs[1..], 1..) |binding, j| {
                    std.debug.assert(binding.asPrimitivePin() == .value);
                    if (maybe_create_from_type != null and !std.meta.eql(maybe_create_from_type.?, binding.asPrimitivePin())) {
                        continue;
                    }

                    if (search_input.len != 0) {
                        const matches_search = std.ascii.indexOfIgnoreCase(binding.name, search_input) != null;
                        if (!matches_search) continue;
                    }

                    var label_buf: [MAX_FUNC_NAME]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buf, "Get {s}", .{binding.name});

                    if (try dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal, .id_extra = j }) != null) {
                        var buf: [MAX_FUNC_NAME]u8 = undefined;
                        const name = try std.fmt.bufPrint(&buf, "get_{s}", .{binding.name});
                        _ = try NodeAdder.addNode(self, name, maybe_create_from, pt_in_graph, 0);
                        subfw.close();
                    }
                }
            }
        }

        if (try dvui.menuItemLabel(@src(), "Set Params >", .{ .submenu = true }, .{ .expand = .horizontal })) |r| {
            var subfw = try dvui.floatingMenu(@src(), Rect.fromPoint(dvui.Point{ .x = r.x + r.w, .y = r.y }), .{});
            defer subfw.deinit();

            for (self.current_graph.grappl_graph.entry_node_basic_desc.outputs[1..], 1..) |binding, j| {
                var buf: [MAX_FUNC_NAME]u8 = undefined;
                const name = try std.fmt.bufPrint(&buf, "set_{s}", .{binding.name});
                const node_desc = self.current_graph.env.getNode(name) orelse unreachable;

                var valid_socket_index: ?u16 = null;
                if (maybe_create_from_type) |create_from_type| {
                    valid_socket_index = try NodeAdder.validSocketIndex(node_desc, maybe_create_from.?, create_from_type);
                    if (valid_socket_index == null)
                        continue;
                }

                if (search_input.len != 0) {
                    const matches_search = std.ascii.indexOfIgnoreCase(binding.name, search_input) != null;
                    if (!matches_search) continue;
                }

                var label_buf: [MAX_FUNC_NAME]u8 = undefined;
                const label = try std.fmt.bufPrint(&label_buf, "Set {s}", .{binding.name});

                if (try dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal, .id_extra = j }) != null) {
                    _ = try NodeAdder.addNode(self, name, maybe_create_from, pt_in_graph, valid_socket_index);
                    subfw.close();
                }
            }
        }
    }

    {
        // FIXME: replace with node iterator
        var node_iter = self.current_graph.env.nodeIterator();
        var i: u32 = 0;
        while (node_iter.next()) |node_desc| {
            const node_name = node_desc.name();

            switch (node_desc.kind) {
                .func, .return_, .entry => {},
                .get, .set => continue, // handled separately above
            }

            // TODO: add an "always" ... or better type resolution/promotion actually
            if (node_desc.hidden)
                continue;

            var valid_socket_index: ?u16 = null;

            if (maybe_create_from_type) |create_from_type| {
                valid_socket_index = try NodeAdder.validSocketIndex(node_desc, maybe_create_from.?, create_from_type);
                if (valid_socket_index == null)
                    continue;
            }

            if (search_input.len != 0) {
                const matches_search = std.ascii.indexOfIgnoreCase(node_name, search_input) != null;
                if (!matches_search) continue;
            }

            if ((try dvui.menuItemLabel(@src(), node_name, .{}, .{ .expand = .horizontal, .id_extra = i })) != null) {
                _ = try NodeAdder.addNode(self, node_name, maybe_create_from, pt_in_graph, valid_socket_index);
                fw.close();
            }
            i += 1;
        }
    }
}

fn renderGraph(self: *@This(), canvas: *dvui.BoxWidget) !void {
    _ = canvas;

    errdefer if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);

    if (self.init_opts.preferences.graph.origin) |origin| {
        ScrollData.origin = origin;
    }
    if (self.init_opts.preferences.graph.scale) |scale| {
        ScrollData.scale = scale;
    }

    const scroll_bar_vis: dvui.ScrollInfo.ScrollBarMode = if (self.init_opts.preferences.graph.scrollBarsVisible) |v|
        if (v) .show else .hide
    else
        .auto;

    var graph_area = try dvui.scrollArea(
        @src(),
        .{
            .scroll_info = &ScrollData.scroll_info,
            .vertical_bar = scroll_bar_vis,
            .horizontal_bar = scroll_bar_vis,
        },
        .{
            .expand = .both,
            .color_fill = .{ .name = .fill_window },
            .corner_radius = Rect.all(0),
            // FIXME: why?
            .min_size_content = dvui.Size{ .w = 300, .h = 300 },
        },
    );

    // can use this to convert between viewport/virtual_size and screen coords
    const scrollRectScale = graph_area.scroll.screenRectScale(.{});

    var scaler = try dvui.scale(@src(), ScrollData.scale, .{ .rect = .{ .x = -ScrollData.origin.x, .y = -ScrollData.origin.y } });

    // can use this to convert between data and screen coords
    const dataRectScale = scaler.screenRectScale(.{});

    // origin
    // try dvui.pathAddPoint(dataRectScale.pointToScreen(.{ .x = -10 }));
    // try dvui.pathAddPoint(dataRectScale.pointToScreen(.{ .x = 10 }));
    // try dvui.pathStroke(false, 1, .none, dvui.Color.black);

    // try dvui.pathAddPoint(dataRectScale.pointToScreen(.{ .y = -10 }));
    // try dvui.pathAddPoint(dataRectScale.pointToScreen(.{ .y = 10 }));
    // try dvui.pathStroke(false, 1, .none, dvui.Color.black);

    // TODO: use link struct?
    var socket_positions = std.AutoHashMapUnmanaged(Socket, dvui.Point){};
    defer socket_positions.deinit(gpa);

    const mouse_pt = dvui.currentWindow().mouse_pt;
    //var mouse_pt2 = graph_area.scroll.data().contentRectScale().pointFromScreen(dvui.currentWindow().mouse_pt);
    //mouse_pt2 = mouse_pt.plus(ScrollData.origin).plus(ScrollData.scroll_info.viewport.topLeft());

    var mbbox: ?Rect = null;

    // set drag end to false, rendering nodes will determine if it should still be set
    self.edge_drag_end = null;

    // place nodes
    {
        var node_iter = self.current_graph.grappl_graph.nodes.map.iterator();
        while (node_iter.next()) |entry| {
            // TODO: don't iterate over unneeded keys
            //const node_id = entry.key_ptr.*;
            const node = entry.value_ptr;
            const node_rect = try renderNode(self, node, &socket_positions, graph_area, dataRectScale);

            if (mbbox != null) {
                mbbox = mbbox.?.unionWith(node_rect);
            } else {
                mbbox = node_rect;
            }
        }
    }

    // place edges
    {
        var node_iter = self.current_graph.grappl_graph.nodes.map.iterator();
        while (node_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            const node = entry.value_ptr;

            for (node.inputs, 0..) |input, input_index| {
                if (input != .link)
                    continue;

                const target = Socket{
                    .node_id = node_id,
                    .kind = .input,
                    .index = @intCast(input_index),
                };

                const source_pos = socket_positions.get(target) orelse {
                    std.log.err("bad output_pos {any}", .{target});
                    continue;
                };

                const source = Socket{
                    .node_id = input.link.target,
                    .kind = .output,
                    .index = input.link.pin_index,
                };

                const target_pos = socket_positions.get(source) orelse {
                    std.log.err("bad input_pos {any}", .{source});
                    continue;
                };

                // FIXME: dedup with below edge drawing
                try dvui.pathAddPoint(source_pos);
                try dvui.pathAddPoint(target_pos);
                const stroke_color = dvui.Color{ .r = 0xaa, .g = 0xaa, .b = 0xaa, .a = 0xee };
                // TODO: need to handle deletion...
                try dvui.pathStroke(false, 3.0, .none, stroke_color);
            }
        }
    }

    var drop_node_menu = false;

    // maybe currently dragged edge
    {
        const cw = dvui.currentWindow();
        const maybe_drag_offset = if (cw.drag_state != .none) cw.drag_offset else null;

        if (maybe_drag_offset != null and self.edge_drag_start != null) {
            const drag_start = self.edge_drag_start.?.pt;
            const drag_end = mouse_pt;
            // FIXME: dedup with above edge drawing
            try dvui.pathAddPoint(drag_start);
            try dvui.pathAddPoint(drag_end);
            const stroke_color = dvui.Color{ .r = 0xaa, .g = 0xaa, .b = 0xaa, .a = 0x88 };
            try dvui.pathStroke(false, 3.0, .none, stroke_color);
        }

        const drag_state_changed = (self.prev_drag_state == null) != (maybe_drag_offset == null);

        const stopped_dragging = drag_state_changed and maybe_drag_offset == null and self.edge_drag_start != null;

        if (stopped_dragging) {
            if (self.edge_drag_end) |end| {
                const edge = if (end.kind == .input) .{
                    .source = self.edge_drag_start.?.socket,
                    .target = end,
                } else .{
                    .source = end,
                    .target = self.edge_drag_start.?.socket,
                };

                const same_edge = edge.source.node_id == edge.target.node_id;
                const valid_edge = edge.source.kind != edge.target.kind and !same_edge;
                if (valid_edge) {
                    // FIXME: why am I assuming edge_drag_start exists?
                    // TODO: maybe use unreachable instead of try?
                    try self.current_graph.addEdge(
                        gpa,
                        edge.source.node_id,
                        edge.source.index,
                        edge.target.node_id,
                        edge.target.index,
                        0,
                    );
                }
            } else {
                drop_node_menu = true;
                self.node_menu_filter = if (self.edge_drag_start != null) self.edge_drag_start.?.socket else null;
            }

            self.edge_drag_start = null;
        }

        self.prev_drag_state = maybe_drag_offset;
    }

    if (drop_node_menu) {
        dvui.dataSet(null, self.context_menu_widget_id orelse unreachable, "_activePt", mouse_pt);
        dvui.focusWidget(self.context_menu_widget_id orelse unreachable, null, null);
    }

    // set drag cursor
    if (dvui.captured(graph_area.data().id))
        dvui.cursorSet(.hand);

    var zoom: f32 = 1;
    var zoomP: dvui.Point = .{};

    // process scroll area events after nodes so the nodes get first pick (so the button works)
    const scroll_evts = dvui.events();
    for (scroll_evts) |*e| {
        if (!graph_area.scroll.matchEvent(e))
            continue;

        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .press and me.button.pointer()) {
                    e.handled = true;
                    dvui.captureMouse(graph_area.scroll.data().id);
                    dvui.dragPreStart(me.p, .{});
                } else if (me.action == .release and me.button.pointer()) {
                    if (dvui.captured(graph_area.scroll.data().id)) {
                        e.handled = true;
                        dvui.captureMouse(null);
                        dvui.dragEnd(); // NOTE: wasn't in original version
                    }
                } else if (me.action == .motion) {
                    if (me.button.touch()) {
                        // FIXME: check dvui scrollArea sample, why is this commented out?
                        //e.handled = true;
                    }
                    if (dvui.captured(graph_area.scroll.data().id) and self.init_opts.preferences.graph.allowPanning) {
                        if (dvui.dragging(me.p)) |dps| {
                            const rs = scrollRectScale;
                            ScrollData.scroll_info.viewport.x -= dps.x / rs.s;
                            ScrollData.scroll_info.viewport.y -= dps.y / rs.s;
                            dvui.refresh(null, @src(), graph_area.scroll.data().id);
                        }
                    }
                    // TODO: mouse wheel zoom
                } else if (me.action == .wheel_y) {
                    e.handled = true;
                    const base: f32 = 1.005;
                    const zs = @exp(@log(base) * me.data.wheel_y);
                    if (zs != 1.0) {
                        zoom *= zs;
                        zoomP = me.p;
                    }
                }
            },
            else => {},
        }
    }

    if (zoom != 1.0) {
        // scale around mouse point
        // first get data point of mouse
        const prevP = dataRectScale.pointFromScreen(zoomP);

        // scale
        var pp = prevP.scale(1 / ScrollData.scale);
        ScrollData.scale *= zoom;
        pp = pp.scale(ScrollData.scale);

        // get where the mouse would be now
        const newP = dataRectScale.pointToScreen(pp);

        // convert both to viewport
        const diff = scrollRectScale.pointFromScreen(newP).diff(scrollRectScale.pointFromScreen(zoomP));
        ScrollData.scroll_info.viewport.x += diff.x;
        ScrollData.scroll_info.viewport.y += diff.y;

        dvui.refresh(null, @src(), graph_area.scroll.data().id);
    }

    const mp = dvui.currentWindow().mouse_pt;
    // calculate mouse in graph for later after graph deinit and event handling
    // we will use it for renderAddNodeMenu
    const pt_in_graph = dataRectScale.pointFromScreen(mp);

    scaler.deinit();
    // deinit graph area to process events
    graph_area.deinit();

    // don't mess with scrolling if we aren't being shown (prevents weirdness
    // when starting out)
    if (!ScrollData.scroll_info.viewport.empty()) {
        // add current viewport plus padding
        const pad = 10;
        var bbox = ScrollData.scroll_info.viewport.outsetAll(pad);
        if (mbbox) |bb| {
            // convert bb from screen space to viewport space
            const scrollbbox = scrollRectScale.rectFromScreen(bb);
            bbox = bbox.unionWith(scrollbbox);
        }

        // adjust top if needed
        if (bbox.y != 0) {
            const adj = -bbox.y;
            ScrollData.scroll_info.virtual_size.h += adj;
            ScrollData.scroll_info.viewport.y += adj;
            ScrollData.origin.y -= adj;
            dvui.refresh(null, @src(), graph_area.scroll.data().id);
        }

        // adjust left if needed
        if (bbox.x != 0) {
            const adj = -bbox.x;
            ScrollData.scroll_info.virtual_size.w += adj;
            ScrollData.scroll_info.viewport.x += adj;
            ScrollData.origin.x -= adj;
            dvui.refresh(null, @src(), graph_area.scroll.data().id);
        }

        // adjust bottom if needed
        if (bbox.h != ScrollData.scroll_info.virtual_size.h) {
            ScrollData.scroll_info.virtual_size.h = bbox.h;
            dvui.refresh(null, @src(), graph_area.scroll.data().id);
        }

        // adjust right if needed
        if (bbox.w != ScrollData.scroll_info.virtual_size.w) {
            ScrollData.scroll_info.virtual_size.w = bbox.w;
            dvui.refresh(null, @src(), graph_area.scroll.data().id);
        }
    }

    // Now we are after all widgets that deal with drag name "box_transfer".
    // Any mouse release during a drag here means the user released the mouse
    // outside any target widget.
    if (dvui.currentWindow().drag_state != .none) {
        for (dvui.events()) |*e| {
            if (!e.handled and e.evt == .mouse and e.evt.mouse.action == .release) {
                dvui.dragEnd();
                dvui.refresh(null, @src(), null);
            }
        }
    }

    {
        // FIXME: get max size from this from the graph size
        const ctext = try dvui.context(@src(), .{ .rect = graph_area.data().rect }, .{ .expand = .both });
        // FIXME: shouldn't this be set before the usage?
        self.context_menu_widget_id = ctext.wd.id;

        defer ctext.deinit();
        // render add node context menu outside the graph
        if (ctext.activePoint()) |cp| {
            try renderAddNodeMenu(self, cp, pt_in_graph, self.node_menu_filter);
        } else {
            self.node_menu_filter = null;
        }
    }
}

// TODO: contribute this to dvui?
fn rectCenter(r: Rect) dvui.Point {
    return dvui.Point{
        .x = r.x + r.w / 2,
        .y = r.y + r.h / 2,
    };
}

fn rectContainsMouse(r: Rect) bool {
    const mouse_pt = dvui.currentWindow().mouse_pt;
    return r.contains(mouse_pt);
}

// FIXME: can do better than this
var colors = std.AutoHashMap(grappl.Type, dvui.Color).init(gpa);
fn colorForType(t: grappl.Type) !dvui.Color {
    if (colors.get(t)) |color| {
        return color;
    } else {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, t.name, .Deep);
        const hash = hasher.final();
        const as_f32 = @as(f32, @floatFromInt(hash)) / @as(f32, @floatFromInt(std.math.maxInt(@TypeOf(hash))));
        // TODO: something much more balanced
        const color = dvui.Color.fromHSLuv(
            as_f32 * 360,
            100.0,
            50,
            100.0,
        );
        try colors.put(t, color);
        return color;
    }
}

// FIXME: replace with idiomatic dvui event processing
fn considerSocketForHover(self: *@This(), icon_res: *dvui_extra.ButtonIconResult, socket: Socket) dvui.Point {
    const r = icon_res.icon.wd.rectScale().r;
    const socket_center = rectCenter(r);

    // HACK: make this cleaner
    const was_dragging = dvui.currentWindow().drag_state != .none or self.prev_drag_state != null;

    if (rectContainsMouse(r)) {
        if (was_dragging and self.edge_drag_start != null and socket.node_id != self.edge_drag_start.?.socket.node_id) {
            if (socket.kind != self.edge_drag_start.?.socket.kind) {
                dvui.cursorSet(.crosshair);
                self.edge_drag_end = socket;
            } else {
                dvui.toast(@src(), .{ .message = "Can only connect inputs to outputs", .timeout = 1_000_000 }) catch unreachable;
            }
        }

        // FIXME: make more idiomatic
        const evts = dvui.events();
        for (evts) |*e| {
            //if (!icon_res.icon.matchEvent(e))
            //continue;
            switch (e.evt) {
                .mouse => |me| {
                    if (me.action == .press and me.button.pointer()) {
                        dvui.cursorSet(.crosshair);
                        self.edge_drag_start = .{
                            .pt = socket_center,
                            .socket = socket,
                        };
                        break;
                    }
                },
                else => {},
            }
        }
    }

    return socket_center;
}

const exec_color = dvui.Color{ .r = 0x55, .g = 0x55, .b = 0x55, .a = 0xff };

// TODO: remove need for id, it should be inside the node itself
fn renderNode(
    self: *@This(),
    node: *grappl.Node,
    socket_positions: *std.AutoHashMapUnmanaged(Socket, dvui.Point),
    graph_area: *dvui.ScrollAreaWidget,
    dataRectScale: dvui.RectScale,
) !Rect {
    const root_id_extra: usize = @intCast(node.id);

    // FIXME:  this is temp, go back to auto graph formatting
    var maybe_viz_data = self.current_graph.visual_graph.node_data.getPtr(node.id);
    if (maybe_viz_data == null) {
        const putresult = try self.current_graph.visual_graph.node_data.getOrPutValue(gpa, node.id, .{
            .position = dvui.Point{},
            .position_override = null,
        });
        maybe_viz_data = putresult.value_ptr;
    }
    const viz_data = maybe_viz_data.?;
    if (viz_data.position_override == null) {
        viz_data.position_override = viz_data.position;
    }
    const position: *dvui.Point = &viz_data.position_override.?;

    const box = try dvui.box(
        @src(),
        .vertical,
        .{
            .rect = dvui.Rect{
                .x = position.x,
                .y = position.y,
            },
            .id_extra = root_id_extra,
            .debug = true,
            .margin = .{ .h = 5, .w = 5, .x = 5, .y = 5 },
            .padding = .{ .h = 5, .w = 5, .x = 5, .y = 5 },
            .background = true,
            .border = .{ .h = 1, .w = 1, .x = 1, .y = 1 },
            .corner_radius = Rect.all(8),
            .color_border = .{ .color = dvui.Color.black },
            //.max_size_content = dvui.Size{ .w = 300, .h = 600 },
        },
    );
    defer box.deinit();

    const result = box.data().rectScale().r; // already has origin added (already in scroll coords)

    // FIXME: do this better
    // FIXME: maybe remove node.kind since we need a desc anyway?
    switch (node.desc().kind) {
        .func, .entry, .return_ => try dvui.label(@src(), "{s}", .{node.desc().name()}, .{ .font_style = .title_3 }),
        .get => try dvui.label(@src(), "Get {s}", .{node.desc().name()[4..]}, .{ .font_style = .title_3 }),
        .set => try dvui.label(@src(), "Set {s}", .{node.desc().name()[4..]}, .{ .font_style = .title_3 }),
    }

    // switch (node.kind) {
    //     .desc => |desc| try dvui.label(@src(), "{s}", .{desc.name()}, .{ .font_style = .title_3 }),
    //     .get => |v| try dvui.label(@src(), "Get {s}", .{v.binding.name}, .{ .font_style = .title_3 }),
    //     .set => |v| try dvui.label(@src(), "Set {s}", .{v.binding.name}, .{ .font_style = .title_3 }),
    // }

    var hbox = try dvui.box(@src(), .horizontal, .{});
    defer hbox.deinit();

    {
        var inputs_vbox = try dvui.box(@src(), .vertical, .{});
        defer inputs_vbox.deinit();
        for (node.desc().getInputs(), node.inputs, 0..) |*input_desc, *input, j| {
            var input_box = try dvui.box(@src(), .horizontal, .{ .id_extra = j });
            defer input_box.deinit();

            const socket = Socket{ .node_id = node.id, .kind = .input, .index = @intCast(j) };

            const color = if (input_desc.kind == .primitive and input_desc.kind.primitive == .value)
                try colorForType(input_desc.kind.primitive.value)
            else
                exec_color;

            const icon_opts = dvui.Options{
                .min_size_content = .{ .h = 20, .w = 20 },
                .gravity_y = 0.5,
                .id_extra = j,
                .color_fill = .{ .color = color },
                .color_fill_hover = .{ .color = .{ .r = color.r, .g = color.g, .b = color.b, .a = 0x88 } },
                .debug = true,
                .border = dvui.Rect{},
                .background = true,
            };

            const socket_point: dvui.Point = if (
            //
            input_desc.kind.primitive == .exec
            //
            or input_desc.kind.primitive.value == helpers.primitive_types.code
            //
            ) _: {
                var icon_res = try dvui_extra.buttonIconResult(@src(), "arrow_with_circle_right", entypo.arrow_with_circle_right, .{}, icon_opts);
                const socket_center = considerSocketForHover(self, &icon_res, socket);
                if (icon_res.clicked) {
                    // FIXME: add an "input" reset
                    input.* = .{ .value = .{ .float = 0.0 } };
                }

                break :_ socket_center;
            } else _: {
                // FIXME: make non interactable/hoverable

                var icon_res = try dvui_extra.buttonIconResult(@src(), "circle", entypo.circle, .{}, icon_opts);
                const socket_center = considerSocketForHover(self, &icon_res, socket);
                if (icon_res.clicked) {
                    input.* = .{ .value = .{ .int = 0 } };
                }

                // FIXME: report compiler bug
                // } else switch (i.kind.primitive.value) {
                //     grappl.primitive_types.i32_ => {
                if (input.* != .link) {
                    // TODO: handle all possible types using switch or something
                    var handled = false;

                    inline for (.{ i32, i64, u32, u64, f32, f64 }) |T| {
                        const primitive_type = @field(grappl.primitive_types, @typeName(T) ++ "_");
                        if (input_desc.kind.primitive.value == primitive_type) {
                            var value: T = undefined;
                            // FIXME: why even do this if we're about to overwrite it
                            // with the entry info?
                            if (input.* == .value) {
                                switch (input.value) {
                                    .float => |v| {
                                        value = if (@typeInfo(T) == .Int)
                                            @intFromFloat(v)
                                        else
                                            @floatCast(v);
                                    },
                                    .int => |v| {
                                        value = if (@typeInfo(T) == .Int)
                                            @intCast(v)
                                        else
                                            @floatFromInt(v);
                                    },
                                    else => value = 0,
                                }
                            }

                            const entry = try dvui.textEntryNumber(@src(), T, .{ .value = &value }, .{ .max_size_content = .{ .w = 30 }, .id_extra = j });

                            if (entry.value == .Valid) {
                                switch (@typeInfo(T)) {
                                    .Int => {
                                        input.* = .{ .value = .{ .int = @intCast(entry.value.Valid) } };
                                    },
                                    .Float => {
                                        input.* = .{ .value = .{ .float = @floatCast(entry.value.Valid) } };
                                    },
                                    inline else => std.debug.panic("unhandled input type='{s}'", .{@tagName(input.value)}),
                                }
                            }

                            handled = true;
                        }
                    }

                    if (input_desc.kind.primitive.value == grappl.primitive_types.bool_ and input.* == .value) {
                        //node.inputs[j] = .{.literal}
                        if (input.* != .value or input.value != .bool) {
                            input.* = .{ .value = .{ .bool = false } };
                        }

                        _ = try dvui.checkbox(@src(), &input.value.bool, null, .{ .id_extra = j });
                        handled = true;
                    }

                    if (input_desc.kind.primitive.value == grappl.primitive_types.symbol and input.* == .value) {
                        if (self.current_graph.grappl_graph.locals.items.len > 0) {
                            //node.inputs[j] = .{.literal}
                            if (input.* != .value or input.value != .symbol) {
                                input.* = .{ .value = .{ .symbol = "" } };
                            }

                            // TODO: use stack buffer with reasonable max options?
                            const local_options: [][]const u8 = try gpa.alloc([]const u8, self.current_graph.grappl_graph.locals.items.len);
                            defer gpa.free(local_options);

                            var local_choice: usize = 0;

                            for (self.current_graph.grappl_graph.locals.items, local_options, 0..) |local, *local_opt, k| {
                                local_opt.* = local.name;
                                // FIXME: symbol interning
                                if (std.mem.eql(u8, local.name, input.value.symbol)) {
                                    local_choice = k;
                                }
                            }

                            const opt_clicked = try dvui.dropdown(@src(), local_options, &local_choice, .{ .id_extra = j });
                            if (opt_clicked) {
                                input.value = .{ .symbol = self.current_graph.grappl_graph.locals.items[local_choice].name };
                            }
                        } else {
                            try dvui.label(@src(), "No locals", .{}, .{ .id_extra = j });
                        }
                        handled = true;
                    }

                    inline for (.{
                        .{
                            .type = grappl.primitive_types.string,
                            .tag = .string,
                        },
                        .{
                            .type = grappl.primitive_types.symbol,
                            .tag = .symbol,
                        },
                    }, 0..) |info, k| {
                        const id_extra = (j << 1) | k;
                        if (input_desc.kind.primitive.value == info.type and input.* == .value) {
                            const empty = "";
                            if (input.* != .value or input.value != info.tag) {
                                input.* = .{ .value = @unionInit(grappl.Value, @tagName(info.tag), empty) };
                            }

                            const text_result = try dvui.textEntry(@src(), .{ .text = .{ .internal = .{} } }, .{ .id_extra = id_extra });
                            defer text_result.deinit();
                            if (dvui.firstFrame(text_result.data().id)) {
                                text_result.textTyped(@field(input.value, @tagName(info.tag)), false);
                            }
                            // TODO: don't dupe this memory! use a dynamic buffer instead
                            if (text_result.text_changed) {
                                if (@field(input.value, @tagName(info.tag)).ptr != empty.ptr)
                                    gpa.free(@field(input.value, @tagName(info.tag)));
                                @field(input.value, @tagName(info.tag)) = try gpa.dupe(u8, text_result.getText());
                            }

                            handled = true;
                        }
                    }

                    if (input_desc.kind.primitive.value == grappl.primitive_types.char_ and input.* == .value) {
                        const empty_str = "";
                        if (input.* != .value or input.value != .string) {
                            input.* = .{ .value = .{ .string = empty_str } };
                        }

                        const text_result = try dvui.textEntry(@src(), .{ .text = .{ .internal = .{ .limit = 1 } } }, .{ .id_extra = j });
                        defer text_result.deinit();
                        // TODO: don't dupe this memory! use a dynamic buffer instead
                        if (text_result.text_changed) {
                            if (input.value.string.ptr != empty_str.ptr)
                                gpa.free(input.value.string);
                            input.value.string = try gpa.dupe(u8, text_result.getText());
                        }

                        handled = true;
                    }

                    if (!handled)
                        try dvui.label(@src(), "Unknown type: {s}", .{input_desc.kind.primitive.value.name}, .{ .id_extra = j });
                }

                break :_ socket_center;
            };

            try socket_positions.put(gpa, socket, socket_point);

            _ = try dvui.label(@src(), "{s}", .{input_desc.name}, .{ .font_style = .heading, .id_extra = j });
        }
    }

    {
        var outputs_vbox = try dvui.box(@src(), .vertical, .{});
        defer outputs_vbox.deinit();
        for (node.desc().getOutputs(), node.outputs, 0..) |output_desc, *output, j| {
            _ = output;

            var output_box = try dvui.box(@src(), .horizontal, .{ .id_extra = j, .gravity_x = 1.0 });
            defer output_box.deinit();

            const socket = Socket{ .node_id = node.id, .kind = .output, .index = @intCast(j) };

            const color = if (output_desc.kind == .primitive and output_desc.kind.primitive == .value)
                try colorForType(output_desc.kind.primitive.value)
            else
                dvui.Color{ .a = 0x55 };

            const icon_opts = dvui.Options{
                .min_size_content = .{ .h = 20, .w = 20 },
                .gravity_y = 0.5,
                .id_extra = j,
                //
                .debug = true,
                .border = dvui.Rect{},
                .color_fill = .{ .color = color },
                .color_fill_hover = .{ .color = .{ .r = color.r, .g = color.g, .b = color.b, .a = 0x88 } },
                .background = true,
            };

            _ = try dvui.label(@src(), "{s}", .{output_desc.name}, .{ .font_style = .heading, .id_extra = j });

            var icon_res = if (output_desc.kind.primitive == .exec)
                try dvui_extra.buttonIconResult(@src(), "arrow_with_circle_right", entypo.arrow_with_circle_right, .{}, icon_opts)
            else
                try dvui_extra.buttonIconResult(@src(), "circle", entypo.circle, .{}, icon_opts);

            if (icon_res.clicked) {
                // NOTE: hopefully this gets inlined...
                try self.current_graph.removeOutputLinks(node.id, @intCast(j));
            }

            const socket_center = considerSocketForHover(self, &icon_res, socket);
            try socket_positions.put(gpa, socket, socket_center);
        }
    }

    var ctrl_down = dvui.dataGet(null, box.data().id, "_ctrl", bool) orelse false;

    if (dvui.captured(box.data().id) and dvui.currentWindow().drag_state != .none)
        dvui.cursorSet(.hand);

    // process events to drag the box around before processing graph events
    //if (maybe_viz_data) |viz_data| {
    {
        const evts = dvui.events();
        for (evts) |*e| {
            if (e.evt == .key and e.evt.key.matchBind("ctrl/cmd")) {
                ctrl_down = (e.evt.key.action == .down or e.evt.key.action == .repeat);
            }

            if (!box.matchEvent(e))
                continue;

            switch (e.evt) {
                .mouse => |me| {
                    if (me.action == .press and me.button.pointer()) {
                        e.handled = true;
                        dvui.captureMouse(box.data().id);
                        const offset = me.p.diff(box.data().rectScale().r.topLeft()); // pixel offset from box corner
                        dvui.dragPreStart(me.p, .{ .offset = offset });
                        dvui.cursorSet(.hand);
                    } else if (me.action == .release and me.button.pointer()) {
                        if (ctrl_down) {
                            if (self.current_graph.removeNode(node.id)) |removed| {
                                std.debug.assert(removed);
                            } else |err| switch (err) {
                                error.CantRemoveEntry => {},
                                else => return err,
                            }
                        } else if (dvui.captured(box.data().id)) {
                            e.handled = true;
                            dvui.captureMouse(null);
                            dvui.dragEnd();
                        }
                    } else if (me.action == .motion) {
                        if (dvui.captured(box.data().id)) {
                            if (dvui.dragging(me.p)) |_| {
                                const p = me.p.diff(dvui.dragOffset());
                                viz_data.position_override = dataRectScale.pointFromScreen(p);
                                dvui.refresh(null, @src(), graph_area.scroll.data().id);

                                var scrolldrag = dvui.Event{ .evt = .{ .scroll_drag = .{
                                    .mouse_pt = e.evt.mouse.p,
                                    .screen_rect = box.data().rectScale().r,
                                    .capture_id = box.data().id,
                                } } };
                                box.processEvent(&scrolldrag, true);
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    dvui.dataSet(null, box.data().id, "_ctrl", ctrl_down);

    {
        const ctext = try dvui.context(@src(), .{ .rect = result }, .{ .expand = .both });
        if (ctext.activePoint()) |cp| {
            var fw = try dvui.floatingMenu(@src(), Rect.fromPoint(cp), .{});
            defer fw.deinit();
            if (try dvui.menuItemLabel(@src(), "Delete node", .{}, .{ .expand = .horizontal })) |_| {
                if (self.current_graph.removeNode(node.id)) |removed| {
                    std.debug.assert(removed);
                } else |err| switch (err) {
                    error.CantRemoveEntry => {},
                    else => return err,
                }
            }
            // TODO: also add ability to change the type of the node?
        }
        defer ctext.deinit();
    }

    return result;
}

const ScrollData = struct {
    var scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .given };
    var origin: dvui.Point = .{};
    var scale: f32 = 1.0;
};

pub const VisualGraph = struct {
    pub const NodeData = struct {
        // TODO: remove grappl.Node.position
        position: dvui.Point,
        position_override: ?dvui.Point = null,
    };

    graph: *grappl.GraphBuilder,
    // NOTE: should I use an array list?
    node_data: std.AutoHashMapUnmanaged(grappl.NodeId, NodeData) = .{},
    /// graph bounding box
    graph_bb: dvui.Rect = min_graph_bb,

    const min_graph_bb = Rect{ .x = 0, .y = 0, .h = 5, .w = 5 };

    pub fn deinit(self: *VisualGraph, alloc: std.mem.Allocator) void {
        self.node_data.deinit(alloc);
    }

    pub fn addNode(self: *@This(), alloc: std.mem.Allocator, kind: []const u8, is_entry: bool, force_node_id: ?grappl.NodeId, diag: ?*grappl.GraphBuilder.Diagnostic, pos: dvui.Point) !grappl.NodeId {
        // HACK
        const result = try self.graph.addNode(alloc, kind, is_entry, force_node_id, diag);

        try self.node_data.put(gpa, result, .{
            .position = pos,
            .position_override = pos,
        });

        // FIXME:
        // errdefer self.graph.removeNode(result);
        // FIXME: re-enable after demo
        //try self.formatGraphNaive(gpa); // FIXME: do this iteratively! don't reformat the whole thing...
        return result;
    }

    pub fn removeNode(self: *@This(), node_id: grappl.NodeId) !bool {
        if (node_id != self.graph.entry_id) {
            _ = self.node_data.remove(node_id);
        }
        return self.graph.removeNode(node_id);
    }

    pub fn addEdge(self: *@This(), a: std.mem.Allocator, start_id: grappl.NodeId, start_index: u16, end_id: grappl.NodeId, end_index: u16, end_subindex: u16) !void {
        const result = try self.graph.addEdge(a, start_id, start_index, end_id, end_index, end_subindex);
        // FIXME: (note that if edge did any "replacing", that also needs to be restored!)
        // errdefer self.graph.removeEdge(result);
        // FIXME: re-enable after demo
        //try self.formatGraphNaive(gpa); // FIXME: do this iteratively! don't reformat the whole thing...
        return result;
    }

    pub fn removeEdge(self: *@This(), start_id: grappl.NodeId, start_index: u16, end_id: grappl.NodeId, end_index: u16, end_subindex: u16) !void {
        const result = try self.graph.removeEdge(start_id, start_index, end_id, end_index, end_subindex);
        // FIXME: (note that if edge did any "replacing", that also needs to be restored!)
        // errdefer self.graph.removeEdge(result);
        // FIXME: re-enable after demo
        //try self.formatGraphNaive(gpa); // FIXME: do this iteratively! don't reformat the whole thing...
        return result;
    }

    pub fn addLiteralInput(self: @This(), node_id: grappl.NodeId, pin_index: u16, subpin_index: u16, value: grappl.Value) !void {
        return self.graph.addLiteralInput(node_id, pin_index, subpin_index, value);
    }

    /// simple graph formatting that assumes a grid of nodes, and greedily assigns every newly
    /// discovered node to the next available lower vertical slot, in the column to the right
    /// if it's output-discovered or to the left if it's input-discovered
    /// NOTE: the parent_alloc must be preserved
    pub fn formatGraphNaive(in_self: *VisualGraph, parent_alloc: std.mem.Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(parent_alloc);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const Cell = struct {
            node: *const grappl.Node,
            pos: struct {
                x: i32,
                y: i32,
            },
        };

        // grid is a list of columns, each their own list
        //var grid = std.SegmentedList(std.SegmentedList(*grappl.Node, 8), 256){};
        const Col = std.DoublyLinkedList(Cell);
        const Grid = std.DoublyLinkedList(Col);

        var root_grid = Grid{};

        // // Grid nodes are all in an arena, just don't free it!
        // defer {
        //     var col_cursor = root_grid.first;
        //     while (col_cursor) |col| {
        //         var cell_cursor = col.data.first;
        //         while (cell_cursor) |cell| {
        //             arena_alloc.free(cell.data);
        //             cell_cursor = cell.next;
        //         }
        //         col_cursor = col.next;
        //     }
        // }

        var root_visited = try std.DynamicBitSet.initEmpty(arena_alloc, in_self.graph.nodes.map.count());
        defer root_visited.deinit();

        // given a node that's already been placed, place all its connections
        const Local = struct {
            fn impl(
                self: *const VisualGraph,
                alloc: std.mem.Allocator,
                grid: *Grid,
                visited: *std.DynamicBitSet,
                column: *Grid.Node,
                cursor: *Col.Node,
            ) !void {
                inline for (.{ SocketType.input, SocketType.output }) |socket_type| {
                    const sockets = @field(cursor.data.node, @tagName(socket_type) ++ "s");
                    for (sockets, 0..) |maybe_socket, i| {
                        const links = switch (socket_type) {
                            .input => switch (maybe_socket) {
                                .link => |v| _: {
                                    var link = std.SegmentedList(grappl.Link, 2){};
                                    // TODO: pass failing allocator
                                    link.append(alloc, v) catch unreachable;
                                    break :_ link;
                                },
                                else => continue,
                            },
                            .output => maybe_socket.links,
                        };

                        var link_iter = links.constIterator(0);
                        while (link_iter.next()) |link| {
                            if (socket_type == .output and link.isDeadOutput())
                                continue;

                            const was_visited = visited.isSet(@intCast(link.target));

                            if (was_visited) continue;

                            visited.set(@intCast(link.target));

                            const maybe_next_col = switch (socket_type) {
                                .input => column.prev,
                                .output => column.next,
                            };

                            if (maybe_next_col == null) {
                                const new_next_col = try alloc.create(Grid.Node);
                                new_next_col.* = Grid.Node{ .data = Col{} };
                                switch (socket_type) {
                                    .input => grid.prepend(new_next_col),
                                    .output => grid.append(new_next_col),
                                }
                            }

                            const next_col = switch (socket_type) {
                                .input => column.prev.?,
                                .output => column.next.?,
                            };

                            const new_cell = try alloc.create(Col.Node);

                            const node = self.graph.nodes.map.getPtr(link.target) orelse unreachable;

                            new_cell.* = Col.Node{
                                .data = .{
                                    .node = node,
                                    .pos = .{
                                        // FIXME: this is wrong, and not even used
                                        // each column should have an "offset" value
                                        .x = cursor.data.pos.x + switch (socket_type) {
                                            .input => -1,
                                            .output => 1,
                                        },
                                        .y = @intCast(i),
                                    },
                                },
                            };

                            next_col.data.append(new_cell);

                            try impl(self, alloc, grid, visited, next_col, new_cell);
                        }
                    }
                }
            }
        };

        // TODO: consider creating a separate class to handle graph traversals?
        const first_node = in_self.graph.entry() orelse if (in_self.graph.nodes.map.count() > 0)
            (in_self.graph.nodes.map.getPtr(0) orelse return error.NoZeroNodeInNonEmptyGraph)
        else
            return;

        var first_cell = Col.Node{
            .data = Cell{
                .node = first_node,
                .pos = .{ .x = 0, .y = 0 },
            },
        };
        var first_col = Grid.Node{ .data = Col{} };
        first_col.data.append(&first_cell);
        root_grid.append(&first_col);

        try Local.impl(in_self, arena_alloc, &root_grid, &root_visited, &first_col, &first_cell);

        // FIXME: precalc node max sizes
        {
            in_self.graph_bb = min_graph_bb;

            var col_cursor = root_grid.first;
            var i: u32 = 0;
            while (col_cursor) |col| : ({
                col_cursor = col.next;
                i += 1;
            }) {
                var cell_cursor = col.data.first;
                var j: u32 = 0;
                while (cell_cursor) |cell| : ({
                    cell_cursor = cell.next;
                    j += 1;
                }) {
                    // TODO: get more accurate node sizes
                    const node_size = dvui.Size{ .w = 400, .h = 200 };
                    const padding = 20;
                    const node_rect = Rect{
                        .x = @as(f32, @floatFromInt(i)) * node_size.w,
                        .y = @as(f32, @floatFromInt(j)) * node_size.h,
                        .w = node_size.w + padding,
                        .h = node_size.h + padding,
                    };

                    in_self.graph_bb = in_self.graph_bb.unionWith(node_rect);

                    try in_self.node_data.put(parent_alloc, cell.data.node.id, .{
                        .position = .{
                            // FIXME:
                            .x = node_rect.x,
                            .y = node_rect.y,
                        },
                    });
                }
            }
        }
    }
};

pub fn addParamOrResult(
    self: *@This(),
    /// graph entry if param, graph return if result
    node_desc: *const helpers.NodeDesc,
    /// graph entry if param, graph return if result
    node_basic_desc: *helpers.BasicMutNodeDesc,
    comptime kind: enum { params, results },
) !void {
    const pin_dir = comptime if (kind == .params) "outputs" else "inputs";
    const opposite_dir = comptime if (kind == .params) "inputs" else "outputs";

    var pin_descs = @field(node_basic_desc, pin_dir);
    pin_descs = try gpa.realloc(pin_descs, pin_descs.len + 1);
    @field(node_basic_desc, pin_dir) = pin_descs;
    @field(self.current_graph.call_basic_desc, opposite_dir) = pin_descs;

    const new_name = _: {
        var name_suffix = pin_descs.len - 1;

        while (true) : (name_suffix += 1) {
            var buf: [MAX_FUNC_NAME]u8 = undefined;

            const getter_name_attempt = try std.fmt.bufPrint(&buf, "get_a{}", .{name_suffix});
            if (self.current_graph.env._nodes.contains(getter_name_attempt))
                continue;

            const setter_name_attempt = try std.fmt.bufPrint(&buf, "set_a{}", .{name_suffix});
            if (self.current_graph.env._nodes.contains(setter_name_attempt))
                continue;

            // break shouldn't hit the continue above, since we now know it's a good suffix
            break;
        }

        break :_ try std.fmt.allocPrint(gpa, "a{}", .{name_suffix});
    };

    pin_descs[pin_descs.len - 1] = .{
        .name = new_name,
        // i32 is default param for now
        .kind = .{ .primitive = .{
            .value = grappl.primitive_types.i32_,
        } },
    };

    if (kind == .params) {
        const param_get_slot = try gpa.create(helpers.BasicMutNodeDesc);
        param_get_slot.* = .{
            .name = try std.fmt.allocPrint(gpa, "get_{s}", .{new_name}),
            .kind = .get,
            .inputs = &.{},
            .outputs = try gpa.alloc(helpers.Pin, 1),
        };

        param_get_slot.outputs[0] = .{
            .name = new_name,
            .kind = .{ .primitive = .{ .value = grappl.primitive_types.i32_ } },
        };

        (try self.current_graph.param_getters.addOne(gpa)).* = param_get_slot;

        _ = self.current_graph.env.addNode(gpa, helpers.basicMutableNode(param_get_slot)) catch unreachable;

        const param_set_slot = try gpa.create(helpers.BasicMutNodeDesc);
        param_set_slot.* = .{
            .name = try std.fmt.allocPrint(gpa, "set_{s}", .{new_name}),
            .kind = .set,
            .inputs = try gpa.alloc(helpers.Pin, 2),
            .outputs = try gpa.alloc(helpers.Pin, 2),
        };

        param_set_slot.inputs[0] = .{
            .name = "in",
            .kind = .{ .primitive = .exec },
        };
        param_set_slot.inputs[1] = .{
            .name = new_name,
            .kind = .{ .primitive = .{ .value = grappl.primitive_types.i32_ } },
        };

        param_set_slot.outputs[0] = .{
            .name = "out",
            .kind = .{ .primitive = .exec },
        };
        param_set_slot.outputs[1] = .{
            .name = new_name,
            .kind = .{ .primitive = .{ .value = grappl.primitive_types.i32_ } },
        };

        (try self.current_graph.param_setters.addOne(gpa)).* = param_set_slot;

        _ = self.current_graph.env.addNode(gpa, helpers.basicMutableNode(param_set_slot)) catch unreachable;
    }

    {
        // TODO: nodes should not be guaranteed to have the same amount of links as their
        // definition has pins
        // FIXME: we can avoid a linear scan!
        var next = self.graphs.first;
        while (next) |current| : (next = current.next) {
            for (current.data.grappl_graph.nodes.map.values()) |*node| {
                if (node.desc() == node_desc) {
                    const old_pins = @field(node, pin_dir);
                    @field(node, pin_dir) = try gpa.realloc(old_pins, old_pins.len + 1);
                    const pins = @field(node, pin_dir);
                    switch (kind) {
                        .params => {
                            pins[pins.len - 1] = .{};
                        },
                        .results => {
                            pins[pins.len - 1] = .{
                                .value = grappl.Value{ .int = 0 },
                            };
                        },
                    }
                    // the current graph is the one we're adding a param to, so this is checking if other graphs
                    // have calls to this one
                } else if (node.desc() == self.current_graph.call_desc) {
                    const old_pins = @field(node, opposite_dir);
                    @field(node, opposite_dir) = try gpa.realloc(old_pins, old_pins.len + 1);
                    const pins = @field(node, opposite_dir);
                    switch (kind) {
                        .params => {
                            pins[pins.len - 1] = .{
                                .value = grappl.Value{ .int = 0 },
                            };
                        },
                        .results => {
                            pins[pins.len - 1] = null;
                        },
                    }
                } else {
                    continue;
                }
            }
        }
    }
}

pub fn onReceiveLoadedSource(self: *@This(), src: []const u8) !void {
    {
        // TODO: better deinit
        var maybe_cursor = self.graphs.first;
        while (maybe_cursor) |cursor| : (maybe_cursor = cursor.next) {
            cursor.data.deinit();
            gpa.destroy(cursor);
        }
    }

    // FIXME: overwriting without deallocating graphs is a leak!
    // opting to keep for now since cleaning up isn't trivial
    self.graphs = try sourceToGraph(gpa, self, src, &self.shared_env);
}

pub fn frame(self: *@This()) !void {
    // file menu
    if (self.init_opts.preferences.topbar.visible) {
        var m = try dvui.menu(@src(), .horizontal, .{ .background = true, .expand = .horizontal });
        defer m.deinit();

        if (try dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .expand = .none })) |r| {
            var fw = try dvui.floatingMenu(@src(), dvui.Rect.fromPoint(dvui.Point{ .x = r.x, .y = r.y + r.h }), .{});
            defer fw.deinit();

            if (try dvui.menuItemLabel(@src(), "Save", .{}, .{ .expand = .horizontal })) |_| {
                try exportCurrentSource(self);
            }

            if (try dvui.menuItemLabel(@src(), "Open", .{}, .{ .expand = .horizontal })) |_| {
                onRequestLoadSource();
            }

            if (try dvui.menuItemLabel(@src(), "Export Wasm", .{}, .{ .expand = .horizontal })) |_| {
                try exportCurrentCompiled(self);
            }
        }

        if (try dvui.menuItemLabel(@src(), "Go", .{ .submenu = true }, .{ .expand = .none })) |r| {
            var fw = try dvui.floatingMenu(@src(), dvui.Rect.fromPoint(dvui.Point{ .x = r.x, .y = r.y + r.h }), .{});
            defer fw.deinit();

            if (try dvui.menuItemLabel(@src(), "Run (F5)", .{}, .{ .expand = .horizontal })) |_| {
                try runCurrentGraphs(self);
            }

            if (try dvui.menuItemLabel(@src(), "Debug DVUI", .{}, .{ .expand = .horizontal })) |_| {
                dvui.currentWindow().debug_window_show = true;
            }
        }

        if (try dvui.menuItemLabel(@src(), "Help", .{ .submenu = true }, .{ .expand = .none })) |r| {
            var fw = try dvui.floatingMenu(@src(), dvui.Rect.fromPoint(dvui.Point{ .x = r.x, .y = r.y + r.h }), .{});
            defer fw.deinit();
            if (try dvui.menuItemLabel(@src(), "Guide", .{}, .{ .expand = .horizontal })) |_| {
                try dvui.dialog(@src(), .{
                    .modal = true,
                    .title = "Guide",
                    .max_size = .{ .w = 600, .h = 600 },
                    .message =
                    \\Welcome to Graphl
                    \\
                    \\Click in empty space in the graph and drag to pan around.
                    \\Use the mouse wheel to zoom in and out.
                    \\
                    \\Left click and drag from the colored socket of a node to open a menu to select
                    \\from a contextually applicable node to connect.
                    \\Or right click in the graph to create a free node.
                    \\
                    \\Click on a socket to delete any link/edge connected to it.
                    \\Right click on a node to bring up a menu from which you can delete it.
                    \\
                    \\
                    ,
                });
            }
            if (try dvui.menuItemLabel(@src(), "Report issue", .{}, .{ .expand = .horizontal })) |_| {
                onClickReportIssue();
            }
        }

        for (self.init_opts.menus, 0..) |menu, i| {
            // FIXME: must be called recursively to support any-layered submenus
            if (try dvui.menuItemLabel(@src(), menu.name, .{ .submenu = menu.submenus.len > 0 }, .{ .expand = .none, .id_extra = i })) |r| {
                if (menu.on_click) |on_click| {
                    on_click(self.init_opts.context);
                }

                var fw = try dvui.floatingMenu(@src(), Rect.fromPoint(dvui.Point{ .x = r.x, .y = r.y + r.h }), .{ .id_extra = i });
                defer fw.deinit();

                for (menu.submenus, 0..) |submenu, j| {
                    const id_extra = (i << 16) | j;
                    if (try dvui.menuItemLabel(@src(), submenu.name, .{}, .{ .expand = .horizontal, .id_extra = id_extra })) |_| {
                        if (submenu.on_click) |submenu_click| {
                            submenu_click(self.init_opts.context);
                        }
                    }
                }
            }
        }
    }

    //ScrollData.scroll_info.virtual_size = current_graph.visual_graph.graph_bb.size();

    // FIXME: move the viewport to any newly created nodes
    //scroll_info.viewport = current_graph.visual_graph.graph_bb;

    var hbox = try dvui.box(@src(), .horizontal, .{ .expand = .both });
    defer hbox.deinit();

    if (self.init_opts.preferences.definitionsPanel.visible) {
        var defines_box = try dvui.box(@src(), .vertical, .{ .expand = .vertical, .background = true });
        defer defines_box.deinit();

        {
            var box = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal });
            defer box.deinit();

            _ = try dvui.label(@src(), "Functions", .{}, .{ .font_style = .heading });

            const add_clicked = try dvui.buttonIcon(@src(), "add-graph", entypo.plus, .{}, .{});
            if (add_clicked) {
                _ = try addGraph(
                    self,
                    try std.fmt.allocPrint(gpa, "new-func-{}", .{self.next_graph_index}),
                    false,
                );
            }
        }

        {
            var maybe_cursor = self.graphs.first;
            var i: usize = 0;
            while (maybe_cursor) |cursor| : ({
                maybe_cursor = cursor.next;
                i += 1;
            }) {
                var box = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal, .id_extra = i });
                defer box.deinit();

                const entry_state = try dvui.textEntry(@src(), .{}, .{ .id_extra = i });
                // FIXME: use temporary buff and then commit the name after checking it's valid!
                if (entry_state.text_changed) {
                    const old_name = cursor.data.name;
                    defer gpa.free(old_name);
                    const new_name = try gpa.dupe(u8, entry_state.getText());
                    cursor.data.name = new_name;
                    cursor.data.call_basic_desc.name = new_name;
                    std.debug.assert(self.shared_env._nodes.remove(old_name));
                    if (self.shared_env.addNode(gpa, helpers.basicMutableNode(&cursor.data.call_basic_desc))) |result| {
                        cursor.data.call_desc = result;
                    } else |e| switch (e) {
                        error.EnvAlreadyExists => {
                            defer gpa.free(new_name);
                            cursor.data.name = old_name;
                            cursor.data.call_basic_desc.name = old_name;
                            cursor.data.call_desc = self.shared_env.addNode(gpa, helpers.basicMutableNode(&self.current_graph.call_basic_desc)) catch unreachable;
                        },
                        else => return e,
                    }
                }
                if (dvui.firstFrame(entry_state.data().id)) {
                    entry_state.textTyped(cursor.data.name, false);
                }
                entry_state.deinit();

                //_ = try dvui.label(@src(), "()", .{}, .{ .font_style = .body, .id_extra = i });
                const graph_clicked = try dvui.buttonIcon(@src(), "open-graph", entypo.chevron_right, .{}, .{ .id_extra = i });
                if (graph_clicked)
                    self.current_graph = &cursor.data;
            }
        }

        // TODO: hoist to somewhere else?
        // FIXME: don't allocate!
        // TODO: use a map or keep this sorted?
        const type_options = _: {
            const result = try gpa.alloc([]const u8, self.current_graph.env.typeCount());
            var i: usize = 0;
            var type_iter = self.current_graph.env.typeIterator();
            while (type_iter.next()) |type_entry| : (i += 1) {
                result[i] = type_entry.*.name;
            }
            break :_ result;
        };
        defer gpa.free(type_options);

        const bindings_infos = &.{
            //.{ .binding_group = &current_graph.grappl_graph.imports, .name = "Imports" },
            .{ .data = &self.current_graph.grappl_graph.locals, .name = "Locals", .type = .locals },
            //.{ .data = &current_graph.grappl_graph.params, .name = "Parameters", .type = .params },
        };

        inline for (bindings_infos, 0..) |bindings_info, i| {
            {
                var box = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal, .id_extra = i });
                defer box.deinit();

                _ = try dvui.label(@src(), bindings_info.name, .{}, .{ .font_style = .heading });

                const add_clicked = try dvui.buttonIcon(@src(), "add-binding", entypo.plus, .{}, .{ .id_extra = i });
                if (add_clicked) {
                    var name_buf: [MAX_FUNC_NAME]u8 = undefined;

                    // FIXME: obviously this could be faster by keeping track of state
                    const name = try gpa.dupe(u8, for (0..10_000) |j| {
                        const getter_name = try std.fmt.bufPrint(&name_buf, "get_new{}", .{j});
                        // FIXME: use contains
                        if (self.current_graph.env.getNode(getter_name) != null)
                            continue;
                        const name = try std.fmt.bufPrint(&name_buf, "new{}", .{j});
                        break name;
                    } else {
                        return error.MaxItersFindingFreeBindingName;
                    });

                    errdefer gpa.free(name);

                    // default binding type
                    const new_type = grappl.primitive_types.f64_;

                    const getter_inputs = [_]helpers.Pin{};

                    const getter_outputs = [_]helpers.Pin{
                        helpers.Pin{
                            .name = "value",
                            .kind = .{ .primitive = .{ .value = new_type } },
                        },
                    };

                    const setter_inputs = [_]helpers.Pin{
                        helpers.Pin{
                            .name = "",
                            .kind = .{ .primitive = .exec },
                        },
                        helpers.Pin{
                            .name = "new value",
                            .kind = .{ .primitive = .{ .value = new_type } },
                        },
                    };

                    const setter_outputs = [_]helpers.Pin{
                        helpers.Pin{
                            .name = "",
                            .kind = .{ .primitive = .exec },
                        },
                        helpers.Pin{
                            .name = "value",
                            .kind = .{ .primitive = .{ .value = new_type } },
                        },
                    };

                    const node_descs = try gpa.alloc(grappl.helpers.BasicMutNodeDesc, 2);
                    node_descs[0] = grappl.helpers.BasicMutNodeDesc{
                        .name = try std.fmt.allocPrint(gpa, "get_{s}", .{name}),
                        .kind = .get,
                        .inputs = try gpa.dupe(helpers.Pin, &getter_inputs),
                        .outputs = try gpa.dupe(helpers.Pin, &getter_outputs),
                    };
                    errdefer gpa.free(node_descs[0].name);
                    errdefer gpa.free(node_descs[0].inputs);
                    errdefer gpa.free(node_descs[0].outputs);
                    node_descs[1] = grappl.helpers.BasicMutNodeDesc{
                        // FIXME: leaks
                        .name = try std.fmt.allocPrint(gpa, "set_{s}", .{name}),
                        .kind = .set,
                        .inputs = try gpa.dupe(helpers.Pin, &setter_inputs),
                        .outputs = try gpa.dupe(helpers.Pin, &setter_outputs),
                    };
                    errdefer gpa.free(node_descs[1].name);
                    errdefer gpa.free(node_descs[1].inputs);
                    errdefer gpa.free(node_descs[1].outputs);

                    // FIXME: move all this to "addLocal" and "addParam" functions
                    // of the graph which manage the nodes for you
                    _ = try self.current_graph.env.addNode(gpa, helpers.basicMutableNode(&node_descs[0]));
                    _ = try self.current_graph.env.addNode(gpa, helpers.basicMutableNode(&node_descs[1]));

                    const appended = try bindings_info.data.addOne(gpa);

                    // FIXME: leaks!
                    appended.* = .{
                        .name = name,
                        .type_ = new_type,
                        .default = Sexp{ .value = .{ .int = 1 } },
                        .extra = node_descs.ptr,
                    };
                }
            }

            for (bindings_info.data.items, 0..) |*binding, j| {
                const i_needed_bits = comptime std.math.log2_int_ceil(usize, bindings_infos.len);
                // NOTE: we could assert before the loop because we know the bounds
                std.debug.assert(((j << @intCast(i_needed_bits)) & i) == 0);
                const id_extra = (j << @intCast(i_needed_bits)) | i;

                var box = try dvui.box(@src(), .horizontal, .{ .id_extra = id_extra });
                defer box.deinit();

                const text_entry = try dvui.textEntry(@src(), .{}, .{ .id_extra = id_extra });
                if (text_entry.text_changed) {
                    const new_name = try gpa.dupe(u8, text_entry.getText());
                    binding.name = new_name;
                    if (binding.extra) |extra| {
                        const nodes: *[2]grappl.helpers.BasicMutNodeDesc = @alignCast(@ptrCast(extra));
                        const get_node = &nodes[0];
                        const set_node = &nodes[1];
                        // TODO: REPORT ME... allocator doesn't seem to return right slice len
                        // when freeing right before resetting?
                        const old_get_node_name = get_node.name;
                        get_node.name = try std.fmt.allocPrint(gpa, "get_{s}", .{new_name});
                        const old_set_node_name = set_node.name;
                        set_node.name = try std.fmt.allocPrint(gpa, "set_{s}", .{new_name});
                        // FIXME: should be able to use removeByPtr here to avoid look up?
                        std.debug.assert(self.current_graph.env._nodes.remove(old_get_node_name));
                        std.debug.assert(self.current_graph.env._nodes.remove(old_set_node_name));
                        _ = try self.current_graph.env.addNode(gpa, helpers.basicMutableNode(get_node));
                        _ = try self.current_graph.env.addNode(gpa, helpers.basicMutableNode(set_node));
                        // TODO: defer these so they still happen in an error
                        gpa.free(old_get_node_name);
                        gpa.free(old_set_node_name);
                    }
                }
                // must occur after text_changed check or this operation will set it
                if (dvui.firstFrame(text_entry.data().id)) {
                    text_entry.textTyped(binding.name, false);
                }
                text_entry.deinit();

                var type_choice: grappl.Type = undefined;
                var type_choice_index: usize = undefined;
                {
                    // FIXME: this is slow to run every frame!
                    // FIXME: assumes iterator is ordered when not mutated
                    var k: usize = 0;
                    var type_iter = self.current_graph.env.typeIterator();
                    while (type_iter.next()) |type_entry| : (k += 1) {
                        if (type_entry == binding.type_) {
                            type_choice = type_entry;
                            type_choice_index = k;
                            break;
                        }
                    }
                }

                const option_clicked = try dvui.dropdown(@src(), type_options, &type_choice_index, .{ .id_extra = j, .color_text = .{ .color = try colorForType(type_choice) } });
                if (option_clicked) {
                    const selected_name = type_options[type_choice_index];
                    binding.type_ = self.current_graph.grappl_graph.env.getType(selected_name) orelse unreachable;
                    if (binding.extra) |extra| {
                        const nodes: *[2]grappl.helpers.BasicMutNodeDesc = @alignCast(@ptrCast(extra));
                        const get_node = &nodes[0];
                        get_node.outputs[0].kind.primitive.value = binding.type_;
                        const set_node = &nodes[1];
                        set_node.inputs[1].kind.primitive.value = binding.type_;
                        set_node.outputs[1].kind.primitive.value = binding.type_;
                    }
                }
            }
        }

        const params_results_bindings = &.{
            // FIXME: uncomment to allow editing results
            // .{
            //     .node_desc = current_graph.grappl_graph.result_node,
            //     .node_basic_desc = current_graph.grappl_graph.result_node_basic_desc,
            //     .name = "Results",
            //     .pin_dir = "inputs",
            //     .type = .results,
            // },
            .{
                .node_desc = self.current_graph.grappl_graph.entry_node,
                .node_basic_desc = self.current_graph.grappl_graph.entry_node_basic_desc,
                .name = "Parameters",
                .pin_dir = "outputs",
                .type = .params,
            },
        };

        inline for (params_results_bindings, 0..) |info, i| {
            var pin_descs = @field(info.node_basic_desc, info.pin_dir);
            {
                var box = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal, .id_extra = i });
                defer box.deinit();

                _ = try dvui.label(@src(), info.name, .{}, .{ .font_style = .heading, .id_extra = i });

                const add_clicked = try dvui.buttonIcon(@src(), "add-binding", entypo.plus, .{}, .{ .id_extra = i });
                if (add_clicked) {
                    try addParamOrResult(self, info.node_desc, info.node_basic_desc, info.type);
                }
            }

            for (pin_descs[1..], 1..) |*pin_desc, j| {
                const id_extra = (j << 8) | i;
                var box = try dvui.box(@src(), .horizontal, .{ .id_extra = id_extra });
                defer box.deinit();

                const text_entry = try dvui.textEntry(@src(), .{}, .{ .id_extra = id_extra });
                if (text_entry.text_changed) {
                    var buf: [MAX_FUNC_NAME]u8 = undefined;

                    const old_get_name = try std.fmt.bufPrint(&buf, "get_{s}", .{pin_desc.name});
                    std.debug.assert(self.current_graph.env._nodes.remove(old_get_name));
                    const old_set_name = try std.fmt.bufPrint(&buf, "set_{s}", .{pin_desc.name});
                    std.debug.assert(self.current_graph.env._nodes.remove(old_set_name));

                    gpa.free(pin_desc.name);
                    pin_desc.name = try gpa.dupe(u8, text_entry.getText());

                    const param_get_slot = self.current_graph.param_getters.items[j - 1];
                    gpa.free(param_get_slot.name);
                    param_get_slot.name = try std.fmt.allocPrint(gpa, "get_{s}", .{pin_desc.name});
                    param_get_slot.outputs[0].name = pin_desc.name;

                    const param_set_slot = self.current_graph.param_setters.items[j - 1];
                    gpa.free(param_set_slot.name);
                    param_set_slot.name = try std.fmt.allocPrint(gpa, "set_{s}", .{pin_desc.name});
                    param_set_slot.inputs[1].name = pin_desc.name;
                    param_set_slot.outputs[1].name = pin_desc.name;

                    _ = try self.current_graph.env.addNode(gpa, helpers.basicMutableNode(param_get_slot));
                    _ = try self.current_graph.env.addNode(gpa, helpers.basicMutableNode(param_set_slot));
                }
                // must occur after text_changed check or this operation will set it
                if (dvui.firstFrame(text_entry.data().id)) {
                    text_entry.textTyped(pin_desc.name, false);
                }
                text_entry.deinit();

                if (pin_desc.kind != .primitive or pin_desc.kind.primitive == .exec)
                    continue;

                // FIXME: this is slow to run every frame!
                var type_choice: grappl.Type = undefined;
                var type_choice_index: usize = undefined;
                {
                    // FIXME: assumes iterator is ordered when not mutated
                    var k: usize = 0;
                    var type_iter = self.current_graph.env.typeIterator();
                    while (type_iter.next()) |type_entry| : (k += 1) {
                        if (pin_desc.kind != .primitive)
                            continue;
                        if (pin_desc.kind.primitive != .value)
                            continue;
                        if (type_entry == pin_desc.kind.primitive.value) {
                            type_choice = type_entry;
                            type_choice_index = k;
                            break;
                        }
                    }
                }

                const option_clicked = try dvui.dropdown(@src(), type_options, &type_choice_index, .{
                    .id_extra = id_extra,
                    .color_text = .{ .color = try colorForType(type_choice) },
                });
                if (option_clicked) {
                    const selected_name = type_options[type_choice_index];
                    const type_ = self.current_graph.grappl_graph.env.getType(selected_name) orelse unreachable;
                    pin_desc.kind.primitive = .{ .value = type_ };
                    if (info.type == .params) {
                        self.current_graph.param_getters.items[j - 1].outputs[0].kind.primitive.value = type_;
                        self.current_graph.param_setters.items[j - 1].inputs[1].kind.primitive.value = type_;
                        self.current_graph.param_setters.items[j - 1].outputs[1].kind.primitive.value = type_;
                    }
                }
            }
        }

        {
            var result_box = try dvui.box(@src(), .vertical, .{
                .expand = .both,
                .background = true,
                .margin = .{ .w = 3.0, .h = 3.0 },
                .color_fill = .{ .color = .{ .r = 0x19, .g = 0x19, .b = 0x19 } },
            });
            defer result_box.deinit();

            var text = try dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            defer text.deinit();

            try text.addText("Result:\n", .{});
            const res_buff = self.init_opts.result_buffer orelse "\x00";
            try text.addText(res_buff[0..std.mem.indexOf(u8, res_buff, "\x00").?], .{});
        }
    }

    try renderGraph(self, hbox);

    // FIXME: this doesn't work
    // left over global events
    for (dvui.events()) |*e| {
        if (!e.handled and e.evt == .key and e.evt.key.code == .f5) {
            e.handled = true;
            try runCurrentGraphs(self);
        }
    }
}

test {
    _ = @import("./app_tests.zig");
}
