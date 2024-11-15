//! Copyright 2024, Michael Belousov
//!

const std = @import("std");
const builtin = @import("builtin");
const WebBackend = @import("WebBackend");
usingnamespace WebBackend.wasm;

const dvui = @import("dvui");
const entypo = @import("dvui").entypo;
const Rect = dvui.Rect;

const grappl = @import("grappl_core");
const compiler = grappl.compiler;
const SexpParser = @import("grappl_core").SexpParser;
const Sexp = @import("grappl_core").Sexp;
const helpers = @import("grappl_core").helpers;

const MAX_FUNC_NAME = 256;

extern fn recvCurrentSource(ptr: ?[*]const u8, len: usize) void;
extern fn runCurrentWat(ptr: ?[*]const u8, len: usize) void;

const grappl_init_buffer: [MAX_FUNC_NAME]u8 = _: {
    var result = std.mem.zeroes([MAX_FUNC_NAME]u8);
    result[0] = '\x1B';
    result[1] = '\x2D';
    result[MAX_FUNC_NAME - 2] = '\x3E';
    result[MAX_FUNC_NAME - 1] = '\x4F';
    break :_ result;
};

export const grappl_init_start: [*]const u8 = switch (builtin.mode) {
    //.Debug => &grappl_init_buffer[0],
    else => @ptrCast(&grappl_init_buffer[0]),
};

// fuck it just ship this crap, WTF: REPORT ME HACK FIXME
const init_buff_offset: isize = switch (builtin.mode) {
    .Debug => 0,
    else => 3,
};

const grappl_real_init_buff: *const [MAX_FUNC_NAME]u8 = @ptrCast(grappl_init_start + init_buff_offset);

const UserFuncList = std.SinglyLinkedList(helpers.BasicMutNodeDesc);
var user_funcs = UserFuncList{};

// FIXME: keep in sync with typescript automatically
const UserFuncTypes = enum(u32) {
    i32_ = 0,
    i64_ = 1,
    f32_ = 2,
    f64_ = 3,
    string = 4,
    code = 5,
    bool = 6,
};

export fn createUserFunc(name_len: u32, input_count: u32, output_count: u32) *const anyopaque {
    const name = grappl_real_init_buff[0..name_len];
    return _createUserFunc(name, input_count, output_count) catch unreachable;
}

export fn addUserFuncInput(func_id: *const anyopaque, index: u32, name_len: u32, input_type: u32) void {
    const name = grappl_real_init_buff[0..name_len];
    return _addUserFuncInput(@alignCast(@ptrCast(func_id)), index, name, @enumFromInt(input_type)) catch unreachable;
}

export fn addUserFuncOutput(func_id: *const anyopaque, index: u32, name_len: u32, output_type: u32) void {
    const name = grappl_real_init_buff[0..name_len];
    return _addUserFuncOutput(@alignCast(@ptrCast(func_id)), index, name, @enumFromInt(output_type)) catch unreachable;
}

fn _createUserFunc(name: []const u8, input_count: u32, output_count: u32) !*const helpers.BasicMutNodeDesc {
    const node = try gpa.create(UserFuncList.Node);
    node.* = UserFuncList.Node{
        .data = .{
            .name = try gpa.dupe(u8, name),
            .hidden = false,
            .inputs = try gpa.alloc(helpers.Pin, input_count + 1), // an extra is inserted for exec
            .outputs = try gpa.alloc(helpers.Pin, output_count + 1), // an extra is inserted for exec
        },
    };
    user_funcs.prepend(node);

    const result = &node.data;

    result.inputs[0] = helpers.Pin{
        .name = "exec",
        .kind = .{ .primitive = .exec },
    };

    result.outputs[0] = helpers.Pin{
        .name = "",
        .kind = .{ .primitive = .exec },
    };

    return result;
}

fn _addUserFuncInput(func_id: *const helpers.BasicMutNodeDesc, index: u32, name: []const u8, input_type_tag: UserFuncTypes) !void {
    const input_type = switch (input_type_tag) {
        .i32_ => grappl.primitive_types.i32_,
        .i64_ => grappl.primitive_types.i64_,
        .f32_ => grappl.primitive_types.f32_,
        .f64_ => grappl.primitive_types.f64_,
        .string => grappl.primitive_types.string,
        .code => grappl.primitive_types.code,
        .bool => grappl.primitive_types.bool_,
    };

    // skip the exec index
    func_id.inputs[index + 1] = helpers.Pin{
        .name = try gpa.dupe(u8, name),
        .kind = .{ .primitive = .{ .value = input_type } },
    };
}

fn _addUserFuncOutput(func_id: *const helpers.BasicMutNodeDesc, index: u32, name: []const u8, output_type_tag: UserFuncTypes) !void {
    const output_type = switch (output_type_tag) {
        .i32_ => grappl.primitive_types.i32_,
        .i64_ => grappl.primitive_types.i64_,
        .f32_ => grappl.primitive_types.f32_,
        .f64_ => grappl.primitive_types.f64_,
        .string => grappl.primitive_types.string,
        .code => grappl.primitive_types.code,
        .bool => grappl.primitive_types.bool_,
    };

    // skip the exec index
    func_id.outputs[index + 1] = helpers.Pin{
        .name = try gpa.dupe(u8, name),
        .kind = .{ .primitive = .{ .value = output_type } },
    };
}

const WriteError = error{};
const LogWriter = std.io.Writer(void, WriteError, writeLog);

fn writeLog(_: void, msg: []const u8) WriteError!usize {
    WebBackend.wasm.wasm_log_write(msg.ptr, msg.len);
    return msg.len;
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = switch (message_level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const msg = level_txt ++ prefix2 ++ format ++ "\n";

    (LogWriter{ .context = {} }).print(msg, args) catch return;
    WebBackend.wasm.wasm_log_flush();
}

pub const std_options: std.Options = .{
    // Overwrite default log handler
    .logFn = logFn,
};

//var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
//const gpa = gpa_instance.allocator();
const gpa = std.heap.wasm_allocator;

var win: dvui.Window = undefined;
var backend: WebBackend = undefined;
var touchPoints: [2]?dvui.Point = [_]?dvui.Point{null} ** 2;
var orig_content_scale: f32 = 1.0;
var shared_env: grappl.Env = undefined;

const Graph = struct {
    index: u16,

    name_buff: [MAX_FUNC_NAME]u8 = undefined,
    name_len: usize = 0,

    call_basic_desc: grappl.helpers.BasicMutNodeDesc,
    call_desc: *grappl.NodeDesc,

    grappl_graph: grappl.GraphBuilder,
    // FIXME: merge with visual graph
    visual_graph: VisualGraph,

    env: *grappl.Env,

    pub fn name(self: *@This()) []u8 {
        return self.name_buff[0..self.name_len];
    }

    pub fn env(self: @This()) *const grappl.Env {
        return self.grappl_graph.env;
    }

    pub fn init(index: u16, in_name: []const u8) !@This() {
        var result: @This() = undefined;
        try result.initInPlace(index, in_name);
        return result;
    }

    pub fn initInPlace(self: *@This(), index: u16, in_name: []const u8) !void {
        self.env = &shared_env;

        {
            var maybe_cursor = user_funcs.first;
            while (maybe_cursor) |cursor| : (maybe_cursor = cursor.next) {
                _ = try self.env.addNode(gpa, helpers.basicMutableNode(&cursor.data));
            }
        }

        const grappl_graph = try grappl.GraphBuilder.init(gpa, self.env);

        // NOTE: does this only work because of return value optimization?
        self.* = @This(){
            .index = index,
            .grappl_graph = grappl_graph,
            .visual_graph = undefined,
            .env = self.env,
            .call_basic_desc = undefined,
            .call_desc = undefined,
        };

        self.call_basic_desc = helpers.BasicMutNodeDesc{
            .name = in_name,
            .inputs = grappl_graph.entry_node_basic_desc.outputs,
            .outputs = grappl_graph.result_node_basic_desc.inputs,
        };

        // FIXME: remove node on err
        self.call_desc = try shared_env.addNode(
            gpa,
            helpers.basicMutableNode(&self.call_basic_desc),
        );

        std.debug.assert(in_name.len <= MAX_FUNC_NAME);
        @memcpy(self.name_buff[0..in_name.len], in_name);

        self.visual_graph = VisualGraph{ .graph = &self.grappl_graph };

        std.debug.assert(self.grappl_graph.nodes.map.getPtr(0).?.id == self.grappl_graph.entry_id);
        std.debug.assert(self.grappl_graph.nodes.map.getPtr(1) != null);

        try self.visual_graph.node_data.put(gpa, 0, .{
            .position = dvui.Point{ .x = 200, .y = 200 },
            .position_override = dvui.Point{ .x = 200, .y = 200 },
        });

        try self.visual_graph.node_data.put(gpa, 1, .{
            .position = dvui.Point{ .x = 400, .y = 200 },
            .position_override = dvui.Point{ .x = 400, .y = 200 },
        });
    }

    pub fn deinit(self: *@This()) void {
        self.visual_graph.deinit(gpa);
        self.grappl_graph.deinit(gpa);
        gpa.free(self.name);
    }

    pub fn addNode(self: *@This(), alloc: std.mem.Allocator, kind: []const u8, is_entry: bool, force_node_id: ?grappl.NodeId, diag: ?*grappl.GraphBuilder.Diagnostic, pos: dvui.Point) !grappl.NodeId {
        return self.visual_graph.addNode(alloc, kind, is_entry, force_node_id, diag, pos);
    }

    pub fn addEdge(self: *@This(), start_id: grappl.NodeId, start_index: u16, end_id: grappl.NodeId, end_index: u16, end_subindex: u16) !void {
        return self.visual_graph.addEdge(start_id, start_index, end_id, end_index, end_subindex);
    }

    pub fn removeEdge(self: *@This(), start_id: grappl.NodeId, start_index: u16, end_id: grappl.NodeId, end_index: u16, end_subindex: u16) !void {
        return self.visual_graph.removeEdge(start_id, start_index, end_id, end_index, end_subindex);
    }

    pub fn addLiteralInput(self: @This(), node_id: grappl.NodeId, pin_index: u16, subpin_index: u16, value: grappl.Value) !void {
        return self.visual_graph.addLiteralInput(node_id, pin_index, subpin_index, value);
    }
};

// NOTE: must be singly linked list because Graph contains an internal pointer and cannot be moved!
var graphs = std.SinglyLinkedList(Graph){};
var current_graph: *Graph = undefined;
var next_graph_index: u16 = 0;

fn postCurrentSexp() !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const alloc = arena.allocator();
    defer arena.deinit();

    var bytes = std.ArrayList(u8).init(alloc);
    defer bytes.deinit();

    var maybe_cursor = graphs.first;
    while (maybe_cursor) |cursor| : ({
        if (cursor.next != null)
            try bytes.append('\n');
        maybe_cursor = cursor.next;
    }) {
        const sexp = try cursor.data.grappl_graph.compile(alloc, cursor.data.name());
        defer sexp.deinit(alloc);

        _ = try sexp.write(bytes.writer());
    }

    recvCurrentSource(bytes.items.ptr, bytes.items.len);
}

fn setCurrentGraphByIndex(index: u16) !void {
    if (index == current_graph.index)
        return;

    var maybe_cursor = graphs.first;
    var i = index;
    while (maybe_cursor) |cursor| : ({
        maybe_cursor = cursor.next;
        i -= 1;
    }) {
        if (i == 0) {
            current_graph = &cursor.data;
            return;
        }
    }
    return error.RangeError;
}

fn addGraph(name: []const u8, set_as_current: bool) !*Graph {
    const graph_index = next_graph_index;
    next_graph_index += 1;
    errdefer next_graph_index -= 1;

    var new_graph = try gpa.create(std.SinglyLinkedList(Graph).Node);

    new_graph.* = .{ .data = undefined };
    try new_graph.data.initInPlace(graph_index, name);

    if (set_as_current)
        current_graph = &new_graph.data;

    if (graphs.first == null) {
        graphs.prepend(new_graph);
    } else {
        // FIXME: use reverse list?
        var maybe_cursor = graphs.first;
        while (maybe_cursor) |cursor| : (maybe_cursor = cursor.next) {
            if (cursor.next == null) {
                cursor.insertAfter(new_graph);
                break;
            }
        }
    }

    return &new_graph.data;
}

var context_menu_widget_id: ?u32 = null;
var node_menu_filter: ?Socket = null;

// the start of an attempt to drag an edge out of a socket
var edge_drag_start: ?struct {
    pt: dvui.Point,
    socket: Socket,
} = null;

var prev_drag_state: ?dvui.Point = null;

var edge_drag_end: ?Socket = null;

const AppInitErrorCodes = enum(i32) {
    BackendInitFailed = 0,
    WindowInitFailed = 1,
    GrapplInitFailed = 2,
    EnvInitFailed = 3,
};

export fn app_init(platform_ptr: [*]const u8, platform_len: usize) i32 {
    const platform = platform_ptr[0..platform_len];
    dvui.log.debug("platform: {s}", .{platform});
    const mac = if (std.mem.indexOf(u8, platform, "Mac") != null) true else false;

    backend = WebBackend.init() catch {
        std.log.err("WebBackend failed to init", .{});
        return @intFromEnum(AppInitErrorCodes.BackendInitFailed);
    };
    win = dvui.Window.init(@src(), gpa, backend.backend(), .{ .keybinds = if (mac) .mac else .windows }) catch {
        std.log.err("Window failed to init", .{});
        return @intFromEnum(AppInitErrorCodes.WindowInitFailed);
    };

    {
        shared_env = grappl.Env.initDefault(gpa) catch {
            std.log.err("Grappl env failed to init", .{});
            return @intFromEnum(AppInitErrorCodes.EnvInitFailed);
        };

        const first_graph = addGraph("main", true) catch {
            std.log.err("Grappl Graph failed to init", .{});
            return @intFromEnum(AppInitErrorCodes.GrapplInitFailed);
        };
        _ = first_graph;

        // we know the entry is set by addGraph
        //const entry_index = first_graph.grappl_graph.entry_id orelse unreachable;
        //const plus_index = first_graph.addNode(gpa, "+", false, null, null) catch unreachable;
        //const set_index = first_graph.addNode(gpa, "set!", false, null, null) catch unreachable;
        // const set2_index = first_graph.addNode(gpa, "set!", false, null, null) catch unreachable;
        // const set3_index = first_graph.addNode(gpa, "set!", false, null, null) catch unreachable;
        // const set4_index = first_graph.addNode(gpa, "set!", false, null, null) catch unreachable;
        // const set5_index = first_graph.addNode(gpa, "set!", false, null, null) catch unreachable;
        // const set6_index = first_graph.addNode(gpa, "set!", false, null, null) catch unreachable;
        // const set7_index = first_graph.addNode(gpa, "set!", false, null, null) catch unreachable;
        //first_graph.addEdge(set_index, 0, entry_index, 0, 0) catch unreachable;
        //first_graph.addEdge(plus_index, 0, entry_index, 1, 0) catch unreachable;
        // first_graph.addEdge(set_index, 0, set2_index, 0, 0) catch unreachable;
        // first_graph.addEdge(set2_index, 0, set3_index, 0, 0) catch unreachable;
        // first_graph.addEdge(set3_index, 0, set4_index, 0, 0) catch unreachable;
        // first_graph.addEdge(set4_index, 0, set5_index, 0, 0) catch unreachable;
        // first_graph.addEdge(set5_index, 0, set6_index, 0, 0) catch unreachable;
        // first_graph.addEdge(set6_index, 0, set7_index, 0, 0) catch unreachable;
    }

    // small fonts look bad on the web, so bump the default theme up
    var theme = win.themes.get("Adwaita Light").?;
    //win.themes.put("Adwaita Light", theme.fontSizeAdd(2)) catch {};
    theme = win.themes.get("Adwaita Dark").?;
    //win.themes.put("Adwaita Dark", theme.fontSizeAdd(2)) catch {};
    win.theme = win.themes.get("Adwaita Dark").?;
    //win.theme = win.themes.get("Adwaita Light").?;

    WebBackend.win = &win;

    orig_content_scale = win.content_scale;

    return 0;
}

export fn app_deinit() void {
    win.deinit();
    backend.deinit();
    {
        var maybe_cursor = graphs.first;
        while (maybe_cursor) |cursor| {
            maybe_cursor = cursor.next;
            gpa.destroy(&cursor.data);
        }
    }
}

// return number of micros to wait (interrupted by events) for next frame
// return -1 to quit
export fn app_update() i32 {
    return update() catch |err| {
        std.log.err("{!}", .{err});
        const msg = std.fmt.allocPrint(gpa, "{!}", .{err}) catch "allocPrint OOM";
        WebBackend.wasm.wasm_panic(msg.ptr, msg.len);
        return -1;
    };
}

fn update() !i32 {
    const nstime = win.beginWait(backend.hasEvent());

    try win.begin(nstime);

    // Instead of the backend saving the events and then calling this, the web
    // backend is directly sending the events to dvui
    //try backend.addAllEvents(&win);

    try dvui_frame();

    const end_micros = try win.end(.{});

    backend.setCursor(win.cursorRequested());
    backend.textInputRect(win.textInputRequested());

    const wait_event_micros = win.waitTime(end_micros, null);
    return @intCast(@divTrunc(wait_event_micros, 1000));
}

const SocketType = enum(u1) { input, output };

const Socket = struct {
    node_id: grappl.NodeId,
    kind: SocketType,
    index: u16,
};

fn renderAddNodeMenu(pt: dvui.Point, pt_in_graph: dvui.Point, maybe_create_from: ?Socket) !void {
    var fw = try dvui.floatingMenu(@src(), Rect.fromPoint(pt), .{});
    defer fw.deinit();

    // TODO: handle defocus event
    const Local = struct {
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
            node_name: []const u8,
            _maybe_create_from: ?Socket,
            _pt_in_graph: dvui.Point,
            valid_socket_index: ?u16,
        ) !u32 {
            // TODO: use diagnostic
            const new_node_id = try current_graph.addNode(gpa, node_name, false, null, null, _pt_in_graph);

            if (_maybe_create_from) |create_from| {
                switch (create_from.kind) {
                    .input => {
                        try current_graph.addEdge(
                            new_node_id,
                            valid_socket_index orelse 0,
                            create_from.node_id,
                            create_from.index,
                            0,
                        );
                    },
                    .output => {
                        try current_graph.addEdge(
                            create_from.node_id,
                            create_from.index,
                            new_node_id,
                            valid_socket_index orelse 0,
                            0,
                        );
                    },
                }
            }

            return new_node_id;
        }
    };

    const maybe_create_from_type: ?grappl.PrimitivePin = if (maybe_create_from) |create_from| _: {
        const node = current_graph.grappl_graph.nodes.map.get(create_from.node_id) orelse unreachable;
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
        .{ .data = &current_graph.grappl_graph.locals, .display = "Locals" },
    };

    inline for (bindings_infos, 0..) |bindings_info, i| {
        const bindings = bindings_info.data;

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

                        var label_buf: [MAX_FUNC_NAME]u8 = undefined;
                        const label = try std.fmt.bufPrint(&label_buf, "Get {s}", .{binding.name});

                        if (try dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal, .id_extra = id_extra }) != null) {
                            _ = try Local.addNode(binding.name, maybe_create_from, pt_in_graph, 0);
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
                    const node_desc = current_graph.env.nodes.get(binding.name) orelse unreachable;

                    var valid_socket_index: ?u16 = null;
                    if (maybe_create_from_type) |create_from_type| {
                        valid_socket_index = try Local.validSocketIndex(node_desc, maybe_create_from.?, create_from_type);
                        if (valid_socket_index == null)
                            continue;
                    }

                    var label_buf: [MAX_FUNC_NAME]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buf, "Set {s}", .{binding.name});

                    if (try dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal, .id_extra = id_extra }) != null) {
                        _ = try Local.addNode(name, maybe_create_from, pt_in_graph, valid_socket_index);
                        subfw.close();
                    }
                }
            }
        }
    }

    if (current_graph.grappl_graph.entry_node_basic_desc.outputs.len > 1) {
        if (maybe_create_from == null or maybe_create_from.?.kind == .input) {
            if (try dvui.menuItemLabel(@src(), "Get Params >", .{ .submenu = true }, .{ .expand = .horizontal })) |r| {
                var subfw = try dvui.floatingMenu(@src(), Rect.fromPoint(dvui.Point{ .x = r.x + r.w, .y = r.y }), .{});
                defer subfw.deinit();

                for (current_graph.grappl_graph.entry_node_basic_desc.outputs, 0..) |binding, j| {
                    std.debug.assert(binding.asPrimitivePin() == .value);
                    if (maybe_create_from_type != null and !std.meta.eql(maybe_create_from_type.?, binding.asPrimitivePin())) {
                        continue;
                    }

                    var label_buf: [MAX_FUNC_NAME]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buf, "Get {s}", .{binding.name});

                    if (try dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal, .id_extra = j }) != null) {
                        _ = try Local.addNode(binding.name, maybe_create_from, pt_in_graph, 0);
                        subfw.close();
                    }
                }
            }
        }

        if (try dvui.menuItemLabel(@src(), "Set Params >", .{ .submenu = true }, .{ .expand = .horizontal })) |r| {
            var subfw = try dvui.floatingMenu(@src(), Rect.fromPoint(dvui.Point{ .x = r.x + r.w, .y = r.y }), .{});
            defer subfw.deinit();

            for (current_graph.grappl_graph.entry_node_basic_desc.outputs, 0..) |binding, j| {
                var buf: [MAX_FUNC_NAME]u8 = undefined;
                const name = try std.fmt.bufPrint(&buf, "set_{s}", .{binding.name});
                const node_desc = current_graph.env.nodes.get(binding.name) orelse unreachable;

                var valid_socket_index: ?u16 = null;
                if (maybe_create_from_type) |create_from_type| {
                    valid_socket_index = try Local.validSocketIndex(node_desc, maybe_create_from.?, create_from_type);
                    if (valid_socket_index == null)
                        continue;
                }

                var label_buf: [MAX_FUNC_NAME]u8 = undefined;
                const label = try std.fmt.bufPrint(&label_buf, "Set {s}", .{binding.name});

                if (try dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal, .id_extra = j }) != null) {
                    _ = try Local.addNode(name, maybe_create_from, pt_in_graph, valid_socket_index);
                    subfw.close();
                }
            }
        }
    }

    {
        var node_iter = current_graph.env.nodes.valueIterator();
        var i: u32 = 0;
        while (node_iter.next()) |node| {
            const node_desc = node.*;
            const node_name = node_desc.name();

            switch (node_desc.special) {
                .none => {},
                .get, .set => continue, // handled separately above
            }

            // TODO: add an "always" ... or better type resolution/promotion actually
            if (node_desc.hidden)
                continue;

            var valid_socket_index: ?u16 = null;

            if (maybe_create_from_type) |create_from_type| {
                valid_socket_index = try Local.validSocketIndex(node_desc, maybe_create_from.?, create_from_type);
                if (valid_socket_index == null)
                    continue;
            }

            if ((try dvui.menuItemLabel(@src(), node_name, .{}, .{ .expand = .horizontal, .id_extra = i })) != null) {
                _ = try Local.addNode(node_name, maybe_create_from, pt_in_graph, valid_socket_index);
                fw.close();
            }
            i += 1;
        }
    }
}

fn renderGraph(canvas: *dvui.BoxWidget) !void {
    _ = canvas;

    const ctext = try dvui.context(@src(), .{ .expand = .both });
    context_menu_widget_id = ctext.wd.id;
    defer ctext.deinit();

    var graph_area = try dvui.scrollArea(
        @src(),
        .{ .scroll_info = &ScrollData.scroll_info },
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

    if (ctext.activePoint()) |cp| {
        const mp = dvui.currentWindow().mouse_pt;
        const pt_in_graph = dataRectScale.pointFromScreen(mp);
        try renderAddNodeMenu(cp, pt_in_graph, node_menu_filter);
    } else {
        node_menu_filter = null;
    }

    // TODO: use link struct?
    var socket_positions = std.AutoHashMapUnmanaged(Socket, dvui.Point){};
    defer socket_positions.deinit(gpa);

    const mouse_pt = dvui.currentWindow().mouse_pt;
    //var mouse_pt2 = graph_area.scroll.data().contentRectScale().pointFromScreen(dvui.currentWindow().mouse_pt);
    //mouse_pt2 = mouse_pt.plus(ScrollData.origin).plus(ScrollData.scroll_info.viewport.topLeft());

    var mbbox: ?Rect = null;

    // set drag end to false, rendering nodes will determine if it should still be set
    edge_drag_end = null;

    // place nodes
    {
        var node_iter = current_graph.grappl_graph.nodes.map.iterator();
        while (node_iter.next()) |entry| {
            // TODO: don't iterate over unneeded keys
            //const node_id = entry.key_ptr.*;
            const node = entry.value_ptr;
            const node_rect = try renderNode(node, &socket_positions, graph_area, dataRectScale);

            if (mbbox != null) {
                mbbox = mbbox.?.unionWith(node_rect);
            } else {
                mbbox = node_rect;
            }
        }
    }

    // place edges
    {
        var node_iter = current_graph.grappl_graph.nodes.map.iterator();
        while (node_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            const node = entry.value_ptr;

            for (node.inputs, 0..) |input, input_index| {
                if (input != .link or input.link == null)
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
                    .node_id = input.link.?.target,
                    .kind = .output,
                    .index = input.link.?.pin_index,
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

        if (maybe_drag_offset != null and edge_drag_start != null) {
            const drag_start = edge_drag_start.?.pt;
            const drag_end = mouse_pt;
            // FIXME: dedup with above edge drawing
            try dvui.pathAddPoint(drag_start);
            try dvui.pathAddPoint(drag_end);
            const stroke_color = dvui.Color{ .r = 0xaa, .g = 0xaa, .b = 0xaa, .a = 0x88 };
            try dvui.pathStroke(false, 3.0, .none, stroke_color);
        }

        const drag_state_changed = (prev_drag_state == null) != (maybe_drag_offset == null);

        const stopped_dragging = drag_state_changed and maybe_drag_offset == null and edge_drag_start != null;

        if (stopped_dragging) {
            if (edge_drag_end) |end| {
                const edge = if (end.kind == .input) .{
                    .source = edge_drag_start.?.socket,
                    .target = end,
                } else .{
                    .source = end,
                    .target = edge_drag_start.?.socket,
                };

                const same_edge = edge.source.node_id == edge.target.node_id;
                const valid_edge = edge.source.kind != edge.target.kind and !same_edge;
                if (valid_edge) {
                    // FIXME: why am I assuming edge_drag_start exists?
                    // TODO: maybe use unreachable instead of try?
                    try current_graph.addEdge(
                        edge.source.node_id,
                        edge.source.index,
                        edge.target.node_id,
                        edge.target.index,
                        0,
                    );
                }
            } else {
                drop_node_menu = true;
                node_menu_filter = if (edge_drag_start != null) edge_drag_start.?.socket else null;
            }

            edge_drag_start = null;
        }

        prev_drag_state = maybe_drag_offset;
    }

    if (drop_node_menu) {
        dvui.dataSet(null, context_menu_widget_id orelse unreachable, "_activePt", mouse_pt);
        dvui.focusWidget(context_menu_widget_id orelse unreachable, null, null);
    }

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
                        //e.handled = true;
                    }
                    if (dvui.captured(graph_area.scroll.data().id)) {
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
                    const base: f32 = 1.01;
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

    // deinit graph area to process events
    scaler.deinit();
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
fn considerSocketForHover(icon_res: *dvui.ButtonIconResult, socket: Socket) dvui.Point {
    const r = icon_res.icon.wd.rectScale().r;
    const socket_center = rectCenter(r);

    // HACK: make this cleaner
    const was_dragging = dvui.currentWindow().drag_state != .none or prev_drag_state != null;

    if (rectContainsMouse(r)) {
        if (was_dragging and edge_drag_start != null and socket.node_id != edge_drag_start.?.socket.node_id) {
            if (socket.kind != edge_drag_start.?.socket.kind) {
                dvui.cursorSet(.crosshair);
                edge_drag_end = socket;
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
                        edge_drag_start = .{
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
    node: *grappl.Node,
    socket_positions: *std.AutoHashMapUnmanaged(Socket, dvui.Point),
    graph_area: *dvui.ScrollAreaWidget,
    dataRectScale: dvui.RectScale,
) !Rect {
    const root_id_extra: usize = @intCast(node.id);

    // FIXME:  this is temp, go back to auto graph formatting
    var maybe_viz_data = current_graph.visual_graph.node_data.getPtr(node.id);
    if (maybe_viz_data == null) {
        const putresult = try current_graph.visual_graph.node_data.getOrPutValue(gpa, node.id, .{
            .position = dvui.Point{},
            .position_override = null,
        });
        maybe_viz_data = putresult.value_ptr;
    }
    const viz_data = maybe_viz_data.?;
    if (viz_data.position_override == null) {
        viz_data.position_override = dvui.Point{};
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

    switch (node.kind) {
        .desc => |desc| try dvui.label(@src(), "{s}", .{desc.name()}, .{ .font_style = .title_3 }),
        .get => |v| try dvui.label(@src(), "Get {s}", .{v.binding.name}, .{ .font_style = .title_3 }),
        .set => |v| try dvui.label(@src(), "Set {s}", .{v.binding.name}, .{ .font_style = .title_3 }),
    }

    var hbox = try dvui.box(@src(), .horizontal, .{});
    defer hbox.deinit();

    var inputs_vbox = try dvui.box(@src(), .vertical, .{});

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
            var icon_res = try dvui.buttonIcon(@src(), "arrow_with_circle_right", entypo.arrow_with_circle_right, .{}, icon_opts);
            const socket_center = considerSocketForHover(&icon_res, socket);
            if (icon_res.clicked) {
                input.* = .{ .link = null };
            }

            break :_ socket_center;
        } else _: {
            // FIXME: make non interactable/hoverable

            var icon_res = try dvui.buttonIcon(@src(), "circle", entypo.circle, .{}, icon_opts);
            const socket_center = considerSocketForHover(&icon_res, socket);
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

                        const entry = try dvui.textEntryNumber(@src(), T, .{ .value = &value }, .{ .id_extra = j });

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
                    if (current_graph.grappl_graph.locals.items.len > 0) {
                        //node.inputs[j] = .{.literal}
                        if (input.* != .value or input.value != .symbol) {
                            input.* = .{ .value = .{ .symbol = "" } };
                        }

                        // TODO: use stack buffer with reasonable max options?
                        const local_options: [][]const u8 = try gpa.alloc([]const u8, current_graph.grappl_graph.locals.items.len);
                        defer gpa.free(local_options);

                        var local_choice: usize = 0;

                        for (current_graph.grappl_graph.locals.items, local_options, 0..) |local, *local_opt, k| {
                            local_opt.* = local.name;
                            // FIXME: symbol interning
                            if (std.mem.eql(u8, local.name, input.value.symbol)) {
                                local_choice = k;
                            }
                        }

                        const opt_clicked = try dvui.dropdown(@src(), local_options, &local_choice, .{ .id_extra = j });
                        if (opt_clicked) {
                            input.value = .{ .symbol = current_graph.grappl_graph.locals.items[local_choice].name };
                        }
                    } else {
                        try dvui.label(@src(), "No locals", .{}, .{ .id_extra = j });
                    }
                    handled = true;
                }

                if (input_desc.kind.primitive.value == grappl.primitive_types.string and input.* == .value) {
                    const empty_str = "";
                    if (input.* != .value or input.value != .string) {
                        input.* = .{ .value = .{ .string = empty_str } };
                    }

                    const text_result = try dvui.textEntry(@src(), .{ .text = .{ .internal = .{} } }, .{ .id_extra = j });
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

    inputs_vbox.deinit();

    var outputs_vbox = try dvui.box(@src(), .vertical, .{});

    for (node.desc().getOutputs(), node.outputs, 0..) |output_desc, *output, j| {
        var output_box = try dvui.box(@src(), .horizontal, .{ .id_extra = j });
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
            try dvui.buttonIcon(@src(), "arrow_with_circle_right", entypo.arrow_with_circle_right, .{}, icon_opts)
        else
            try dvui.buttonIcon(@src(), "circle", entypo.circle, .{}, icon_opts);

        if (icon_res.clicked) {
            if (output.*) |o| {
                const target_node = current_graph.grappl_graph.nodes.map.getPtr(o.link.target);
                if (target_node) |target| {
                    // FIXME: need a function for resetting pins of any type, they probably default to 0
                    target.inputs[o.link.pin_index] = .{ .value = .{ .int = 0 } };
                }
            }
            output.* = null;
        }

        const socket_center = considerSocketForHover(&icon_res, socket);
        try socket_positions.put(gpa, socket, socket_center);
    }

    outputs_vbox.deinit();

    // process events to drag the box around before processing graph events
    //if (maybe_viz_data) |viz_data| {
    {
        const evts = dvui.events();
        for (evts) |*e| {
            if (!box.matchEvent(e))
                continue;

            switch (e.evt) {
                .mouse => |me| {
                    if (me.action == .press and me.button.pointer()) {
                        e.handled = true;
                        dvui.captureMouse(box.data().id);
                        const offset = me.p.diff(box.data().rectScale().r.topLeft()); // pixel offset from box corner
                        dvui.dragPreStart(me.p, .{ .offset = offset });
                    } else if (me.action == .release and me.button.pointer()) {
                        if (dvui.captured(box.data().id)) {
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

    pub fn addEdge(self: *@This(), start_id: grappl.NodeId, start_index: u16, end_id: grappl.NodeId, end_index: u16, end_subindex: u16) !void {
        const result = try self.graph.addEdge(start_id, start_index, end_id, end_index, end_subindex);
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
                        const link = switch (socket_type) {
                            .input => switch (maybe_socket) {
                                .link => |v| if (v != null) v.? else continue,
                                else => continue,
                            },
                            .output => (maybe_socket orelse continue).link,
                        };

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

fn dvui_frame() !void {
    var new_content_scale: ?f32 = null;
    var old_dist: ?f32 = null;
    for (dvui.events()) |*e| {
        if (e.evt == .mouse and (e.evt.mouse.button == .touch0 or e.evt.mouse.button == .touch1)) {
            const idx: usize = if (e.evt.mouse.button == .touch0) 0 else 1;
            switch (e.evt.mouse.action) {
                .press => {
                    touchPoints[idx] = e.evt.mouse.p;
                },
                .release => {
                    touchPoints[idx] = null;
                },
                .motion => {
                    if (touchPoints[0] != null and touchPoints[1] != null) {
                        e.handled = true;
                        var dx: f32 = undefined;
                        var dy: f32 = undefined;

                        if (old_dist == null) {
                            dx = touchPoints[0].?.x - touchPoints[1].?.x;
                            dy = touchPoints[0].?.y - touchPoints[1].?.y;
                            old_dist = @sqrt(dx * dx + dy * dy);
                        }

                        touchPoints[idx] = e.evt.mouse.p;

                        dx = touchPoints[0].?.x - touchPoints[1].?.x;
                        dy = touchPoints[0].?.y - touchPoints[1].?.y;
                        const new_dist: f32 = @sqrt(dx * dx + dy * dy);

                        new_content_scale = @max(0.1, win.content_scale * new_dist / old_dist.?);
                    }
                },
                else => {},
            }
        }
    }

    // file menu
    {
        var m = try dvui.menu(@src(), .horizontal, .{ .background = true, .expand = .horizontal });
        defer m.deinit();

        if (try dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .expand = .none })) |r| {
            var fw = try dvui.floatingMenu(@src(), dvui.Rect.fromPoint(dvui.Point{ .x = r.x, .y = r.y + r.h }), .{});
            defer fw.deinit();

            if (try dvui.menuItemLabel(@src(), "Close Menu", .{}, .{}) != null) {
                m.close();
            }
        }

        if (try dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{ .expand = .none })) |r| {
            var fw = try dvui.floatingMenu(@src(), dvui.Rect.fromPoint(dvui.Point{ .x = r.x, .y = r.y + r.h }), .{});
            defer fw.deinit();
            _ = try dvui.menuItemLabel(@src(), "Dummy", .{}, .{ .expand = .horizontal });
            _ = try dvui.menuItemLabel(@src(), "Dummy Long", .{}, .{ .expand = .horizontal });
            _ = try dvui.menuItemLabel(@src(), "Dummy Super Long", .{}, .{ .expand = .horizontal });
        }
    }

    //ScrollData.scroll_info.virtual_size = current_graph.visual_graph.graph_bb.size();

    // FIXME: move the viewport to any newly created nodes
    //scroll_info.viewport = current_graph.visual_graph.graph_bb;

    var hbox = try dvui.box(@src(), .horizontal, .{ .expand = .both });
    defer hbox.deinit();

    {
        var defines_box = try dvui.box(@src(), .vertical, .{ .expand = .vertical, .background = true });
        defer defines_box.deinit();

        var tl = try dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font_style = .title_4 });
        try tl.addText("Grappl Test Editor", .{});
        tl.deinit();

        if (try dvui.button(@src(), "Debug", .{}, .{})) {
            win.debug_window_show = true;
        }

        if (try dvui.button(@src(), "Sync", .{}, .{})) {
            try postCurrentSexp();
        }

        if (try dvui.button(@src(), "Run", .{}, .{})) {
            const sexp = try current_graph.grappl_graph.compile(gpa, "main");
            defer sexp.deinit(gpa);

            var bytes = std.ArrayList(u8).init(gpa);
            defer bytes.deinit();

            if (builtin.mode == .Debug) {
                _ = try sexp.write(bytes.writer());
                std.log.info("sexp:\n{s}", .{bytes.items});
                bytes.clearRetainingCapacity();
            }

            var diagnostic = compiler.Diagnostic.init();

            if (compiler.compile(gpa, &sexp, &user_funcs, &diagnostic)) |module| {
                std.log.info("compile_result:\n{s}", .{module});
                runCurrentWat(module.ptr, module.len);
                gpa.free(module);
            } else |err| {
                std.log.err("compile_error={any}", .{err});
            }
        }

        {
            {
                var box = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal });
                defer box.deinit();

                _ = try dvui.label(@src(), "Functions", .{}, .{ .font_style = .heading });

                const add_clicked = (try dvui.buttonIcon(@src(), "add-graph", entypo.plus, .{}, .{})).clicked;
                if (add_clicked) {
                    _ = try addGraph("new graph", false);
                }
            }

            var maybe_cursor = graphs.first;
            var i: usize = 0;
            while (maybe_cursor) |cursor| : ({
                maybe_cursor = cursor.next;
                i += 1;
            }) {
                var box = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal, .id_extra = i });
                defer box.deinit();

                const entry_state = try dvui.textEntry(@src(), .{ .text = .{ .buffer = &cursor.data.name_buff } }, .{ .id_extra = i });
                cursor.data.name_len = entry_state.getText().len;
                // FIXME: use temporary buff and then commit the name after checking it's valid!
                //if (entry_state.enter_pressed) {}
                entry_state.deinit();

                //_ = try dvui.label(@src(), "()", .{}, .{ .font_style = .body, .id_extra = i });
                const graph_clicked = try dvui.buttonIcon(@src(), "open-graph", entypo.chevron_right, .{}, .{ .id_extra = i });
                if (graph_clicked.clicked)
                    current_graph = &cursor.data;
            }
        }

        // TODO: hoist to somewhere else?
        // FIXME: don't allocate!
        // TODO: use a map or keep this sorted?
        const type_options = _: {
            const result = try gpa.alloc([]const u8, current_graph.env.types.count());
            var i: usize = 0;
            var type_iter = current_graph.env.types.valueIterator();
            while (type_iter.next()) |type_entry| : (i += 1) {
                result[i] = type_entry.*.name;
            }
            break :_ result;
        };
        defer gpa.free(type_options);

        const bindings_infos = &.{
            //.{ .binding_group = &current_graph.grappl_graph.imports, .name = "Imports" },
            .{ .data = &current_graph.grappl_graph.locals, .name = "Locals", .type = .locals },
            //.{ .data = &current_graph.grappl_graph.params, .name = "Parameters", .type = .params },
        };

        inline for (bindings_infos, 0..) |bindings_info, i| {
            {
                var box = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal, .id_extra = i });
                defer box.deinit();

                _ = try dvui.label(@src(), bindings_info.name, .{}, .{ .font_style = .heading });

                const add_clicked = (try dvui.buttonIcon(@src(), "add-binding", entypo.plus, .{}, .{ .id_extra = i })).clicked;
                if (add_clicked) {
                    var name_buf: [MAX_FUNC_NAME]u8 = undefined;

                    // FIXME: leak
                    // FIXME: obviously this could be faster by keeping track of state
                    const name = try gpa.dupe(u8, for (0..10_000) |j| {
                        const name = try std.fmt.bufPrint(&name_buf, "new{}", .{j});
                        if (current_graph.env.nodes.contains(name))
                            continue;
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
                        // FIXME: leaks
                        .name = name,
                        .special = .get,
                        .inputs = try gpa.dupe(helpers.Pin, &getter_inputs),
                        .outputs = try gpa.dupe(helpers.Pin, &getter_outputs),
                    };
                    errdefer gpa.free(node_descs[0].name);
                    node_descs[1] = grappl.helpers.BasicMutNodeDesc{
                        // FIXME: leaks
                        .name = try std.fmt.allocPrint(gpa, "set_{s}", .{name}),
                        .special = .set,
                        .inputs = try gpa.dupe(helpers.Pin, &setter_inputs),
                        .outputs = try gpa.dupe(helpers.Pin, &setter_outputs),
                    };
                    errdefer gpa.free(node_descs[1].name);

                    // FIXME: move all this to "addLocal" and "addParam" functions
                    // of the graph which manage the nodes for you
                    _ = try current_graph.env.addNode(gpa, helpers.basicMutableNode(&node_descs[0]));
                    _ = try current_graph.env.addNode(gpa, helpers.basicMutableNode(&node_descs[1]));

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

                const text_entry_src = @src();
                const text_entry_id = dvui.parentGet().extendId(text_entry_src, id_extra);
                const first_render = !(dvui.dataGet(null, text_entry_id, "_not_first_render", bool) orelse false);
                dvui.dataSet(null, text_entry_id, "_not_first_render", true);

                const text_entry = try dvui.textEntry(text_entry_src, .{}, .{ .id_extra = id_extra });
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
                        get_node.name = new_name;
                        const old_set_node_name = set_node.name;
                        set_node.name = try std.fmt.allocPrint(gpa, "set_{s}", .{new_name});
                        // FIXME: should be able to use removeByPtr here to avoid look up?
                        std.debug.assert(current_graph.env.nodes.remove(old_get_node_name));
                        std.debug.assert(current_graph.env.nodes.remove(old_set_node_name));
                        _ = try current_graph.env.addNode(gpa, helpers.basicMutableNode(get_node));
                        _ = try current_graph.env.addNode(gpa, helpers.basicMutableNode(set_node));
                        gpa.free(old_get_node_name);
                        gpa.free(old_set_node_name);
                    }
                }
                // must occur after text_changed check or this operation will set it
                if (first_render) {
                    text_entry.textTyped(binding.name);
                }
                text_entry.deinit();

                var type_choice: grappl.Type = undefined;
                var type_choice_index: usize = undefined;
                {
                    // FIXME: this is slow to run every frame!
                    // FIXME: assumes iterator is ordered when not mutated
                    var k: usize = 0;
                    var type_iter = current_graph.env.types.valueIterator();
                    while (type_iter.next()) |type_entry| : (k += 1) {
                        if (type_entry.* == binding.type_) {
                            type_choice = type_entry.*;
                            type_choice_index = k;
                            break;
                        }
                    }
                }

                const option_clicked = try dvui.dropdown(@src(), type_options, &type_choice_index, .{ .id_extra = j, .color_text = .{ .color = try colorForType(type_choice) } });
                if (option_clicked) {
                    const selected_name = type_options[type_choice_index];
                    binding.type_ = current_graph.grappl_graph.env.types.get(selected_name) orelse unreachable;
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
            .{
                .node_desc = current_graph.grappl_graph.result_node,
                .node_basic_desc = current_graph.grappl_graph.result_node_basic_desc,
                .name = "Results",
                .pin_dir = "inputs",
                .type = .results,
            },
            .{
                .node_desc = current_graph.grappl_graph.entry_node,
                .node_basic_desc = current_graph.grappl_graph.entry_node_basic_desc,
                .name = "Parameters",
                .pin_dir = "outputs",
                .type = .params,
            },
        };

        inline for (params_results_bindings, 0..) |info, i| {
            var pin_descs = @field(info.node_basic_desc, info.pin_dir);
            const opposite_dir = if (info.type == .params) "inputs" else "outputs";

            {
                var box = try dvui.box(@src(), .horizontal, .{ .expand = .horizontal, .id_extra = i });
                defer box.deinit();

                _ = try dvui.label(@src(), info.name, .{}, .{ .font_style = .heading, .id_extra = i });

                const add_clicked = (try dvui.buttonIcon(@src(), "add-binding", entypo.plus, .{}, .{ .id_extra = i })).clicked;
                if (add_clicked) {
                    const node_basic_desc = info.node_basic_desc;
                    pin_descs = try gpa.realloc(pin_descs, pin_descs.len + 1);
                    @field(node_basic_desc, info.pin_dir) = pin_descs;

                    // FIXME: update call_desc
                    @field(current_graph.call_basic_desc, opposite_dir) = pin_descs;

                    pin_descs[pin_descs.len - 1] = .{
                        .name = "a",
                        // i32 is default param for now
                        .kind = .{ .primitive = .{
                            .value = grappl.primitive_types.i32_,
                        } },
                    };

                    {
                        // TODO: nodes should not be guaranteed to have the same amount of links as their
                        // definition has pins
                        // FIXME: we can avoid a linear scan!
                        for (current_graph.grappl_graph.nodes.map.values()) |*node| {
                            // FIXME: we need to run this across ALL graphs, not just the current one
                            if (node.desc() == info.node_desc) {
                                const pins = @field(node, info.pin_dir);
                                @field(node, info.pin_dir) = try gpa.realloc(pins, pins.len + 1);
                                switch (info.type) {
                                    .params => {
                                        pins[pins.len - 1] = null;
                                    },
                                    .results => {
                                        pins[pins.len - 1] = .{
                                            .value = grappl.Value{ .int = 0 },
                                        };
                                    },
                                    else => unreachable,
                                }
                            } else if (node.desc() == current_graph.call_desc) {
                                const pins = @field(node, opposite_dir);
                                @field(node, opposite_dir) = try gpa.realloc(pins, pins.len + 1);
                                switch (info.type) {
                                    .params => {
                                        pins[pins.len - 1] = .{
                                            .value = grappl.Value{ .int = 0 },
                                        };
                                    },
                                    .results => {
                                        pins[pins.len - 1] = null;
                                    },
                                    else => unreachable,
                                }
                            } else {
                                continue;
                            }
                        }
                    }
                }
            }

            for (pin_descs[1..], 1..) |*pin_desc, j| {
                const id_extra = (j << 8) | i;
                var box = try dvui.box(@src(), .horizontal, .{ .id_extra = id_extra });
                defer box.deinit();

                const text_entry_src = @src();
                const text_entry_id = dvui.parentGet().extendId(text_entry_src, id_extra);
                const first_render = !(dvui.dataGet(null, text_entry_id, "_not_first_render", bool) orelse false);
                dvui.dataSet(null, text_entry_id, "_not_first_render", true);

                const text_entry = try dvui.textEntry(text_entry_src, .{}, .{ .id_extra = id_extra });
                if (text_entry.text_changed) {
                    pin_desc.name = text_entry.getText();
                }
                // must occur after text_changed check or this operation will set it
                if (first_render) {
                    text_entry.textTyped(pin_desc.name);
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
                    var type_iter = current_graph.env.types.valueIterator();
                    while (type_iter.next()) |type_entry| : (k += 1) {
                        if (pin_desc.kind != .primitive)
                            continue;
                        if (pin_desc.kind.primitive != .value)
                            continue;
                        if (type_entry.* == pin_desc.kind.primitive.value) {
                            type_choice = type_entry.*;
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
                    pin_desc.kind.primitive = .{ .value = current_graph.grappl_graph.env.types.get(selected_name) orelse unreachable };
                }
            }
        }
    }

    try renderGraph(hbox);

    // const label = if (dvui.Examples.show_demo_window) "Hide Demo Window" else "Show Demo Window";
    // if (try dvui.button(@src(), label, .{}, .{})) {
    //     dvui.Examples.show_demo_window = !dvui.Examples.show_demo_window;
    // }

    // look at demo() for examples of dvui widgets, shows in a floating window
    //try dvui.Examples.demo();

    if (new_content_scale) |ns| {
        win.content_scale = ns;
    }
}
