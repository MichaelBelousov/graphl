const std = @import("std");
const WebBackend = @import("WebBackend");
usingnamespace WebBackend.wasm;

const dvui = @import("dvui");
const entypo = @import("dvui").entypo;
const Rect = dvui.Rect;

const grappl = @import("grappl_core");

const GraphAreaWidget = @import("./GraphAreaWidget.zig");

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

// TODO: use c_allocator cuz faster?
var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

var win: dvui.Window = undefined;
var backend: WebBackend = undefined;
var touchPoints: [2]?dvui.Point = [_]?dvui.Point{null} ** 2;
var orig_content_scale: f32 = 1.0;

var grappl_graph: grappl.GraphBuilder = undefined;
var visual_graph = VisualGraph{ .graph = &grappl_graph };

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

    const env = grappl.Env.initDefault(gpa) catch {
        std.log.err("Grappl Env failed to init", .{});
        return @intFromEnum(AppInitErrorCodes.GrapplInitFailed);
    };

    grappl_graph = grappl.GraphBuilder.init(gpa, env) catch {
        std.log.err("Grappl Graph failed to init", .{});
        return @intFromEnum(AppInitErrorCodes.GrapplInitFailed);
    };

    {
        const plus_index = visual_graph.addNode(gpa, "+", false, null, null) catch unreachable;
        const set_index = visual_graph.addNode(gpa, "set!", false, null, null) catch unreachable;
        visual_graph.addEdge(plus_index, 0, set_index, 2, 0) catch unreachable;
    }

    // small fonts look bad on the web, so bump the default theme up
    var theme = win.themes.get("Adwaita Light").?;
    win.themes.put("Adwaita Light", theme.fontSizeAdd(2)) catch {};
    theme = win.themes.get("Adwaita Dark").?;
    win.themes.put("Adwaita Dark", theme.fontSizeAdd(2)) catch {};
    win.theme = win.themes.get("Adwaita Light").?;

    WebBackend.win = &win;

    orig_content_scale = win.content_scale;

    return 0;
}

export fn app_deinit() void {
    win.deinit();
    backend.deinit();
    grappl_graph.deinit(gpa);
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
    backend.setOSKPosition(win.OSKRequested());

    const wait_event_micros = win.waitTime(end_micros, null);
    return @intCast(@divTrunc(wait_event_micros, 1000));
}

const SocketType = enum(u1) { input, output };

const Socket = struct {
    node_id: grappl.NodeId,
    kind: SocketType,
    index: u16,
};

fn renderAddNodeMenu(pt: dvui.Point, maybe_create_from: ?Socket) !void {
    var fw2 = try dvui.floatingMenu(@src(), Rect.fromPoint(pt), .{});
    defer fw2.deinit();

    // TODO: handle defocus event

    const maybe_create_from_type: ?grappl.PrimitivePin = if (maybe_create_from) |create_from| _: {
        const node = grappl_graph.nodes.map.get(create_from.node_id) orelse unreachable;
        const pins = switch (create_from.kind) {
            .output => node.desc.getOutputs(),
            .input => node.desc.getInputs(),
        };
        break :_ pins[create_from.index].asPrimitivePin();
    } else null;

    {
        var iter = grappl_graph.env.nodes.iterator();
        var i: u32 = 0;
        while (iter.next()) |node_entry| {
            const node_name = node_entry.key_ptr;
            const node_desc = node_entry.value_ptr;

            var valid_socket_index: ?u16 = null;

            if (maybe_create_from_type) |create_from_type| {
                const pins = switch (maybe_create_from.?.kind) {
                    .input => node_desc.getOutputs(),
                    .output => node_desc.getInputs(),
                };

                if (pins.len > std.math.maxInt(u16))
                    return error.TooManyPins;
                for (pins, 0..) |pin_desc, j| {
                    if (std.meta.eql(pin_desc.asPrimitivePin(), create_from_type)) {
                        valid_socket_index = @intCast(j);
                        break;
                    }
                }

                if (valid_socket_index == null)
                    continue;
            }

            if ((try dvui.menuItemLabel(@src(), node_name.*, .{}, .{ .expand = .horizontal, .id_extra = i })) != null) {
                // TODO: use diagnostic
                const node_id = try visual_graph.addNode(gpa, node_name.*, false, null, null);
                const node = visual_graph.graph.nodes.map.getPtr(node_id) orelse unreachable;
                // HACK
                const mouse_pt = dvui.currentWindow().mouse_pt;
                node.position = .{
                    .x = @intFromFloat(mouse_pt.x),
                    .y = @intFromFloat(mouse_pt.y),
                };

                if (maybe_create_from) |create_from| {
                    switch (create_from.kind) {
                        .input => {
                            // TODO: add it to the first type-compatible socket!
                            try visual_graph.addEdge(
                                node_id,
                                valid_socket_index orelse unreachable,
                                create_from.node_id,
                                create_from.index,
                                0,
                            );
                        },
                        .output => {
                            // TODO: add it to the first type-compatible socket!
                            try visual_graph.addEdge(
                                create_from.node_id,
                                create_from.index,
                                node_id,
                                valid_socket_index orelse unreachable,
                                0,
                            );
                        },
                    }
                }

                fw2.close();
            }
            i += 1;
        }
    }
}

fn renderGraph() !void {
    // TODO: use link struct?
    var socket_positions = std.AutoHashMapUnmanaged(Socket, dvui.Point){};
    defer socket_positions.deinit(gpa);

    // set drag end to false, rendering will determine if it should still be set
    edge_drag_end = null;

    // place nodes
    {
        var node_iter = grappl_graph.nodes.map.iterator();
        while (node_iter.next()) |entry| {
            // TODO: don't iterate over unneeded keys
            //const node_id = entry.key_ptr.*;
            const node = entry.value_ptr;
            try renderNode(node, &socket_positions);
        }
    }

    // place edges
    {
        var node_iter = grappl_graph.nodes.map.iterator();
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
                const stroke_color = dvui.Color{ .r = 0x22, .g = 0x22, .b = 0x22, .a = 0xff };
                // TODO: need to handle deletion...
                try dvui.pathStroke(false, 3.0, .none, stroke_color);
            }
        }
    }

    const mouse_pt = dvui.currentWindow().mouse_pt;
    var drop_node_menu = false;

    // maybe currently dragged edge
    {
        const maybe_drag_offset = dvui.dragging(mouse_pt);

        if (maybe_drag_offset != null and edge_drag_start != null) {
            const drag_start = edge_drag_start.?.pt;
            const drag_end = mouse_pt;
            // FIXME: dedup with above edge drawing
            try dvui.pathAddPoint(drag_start);
            try dvui.pathAddPoint(drag_end);
            const stroke_color = dvui.Color{ .r = 0x22, .g = 0x22, .b = 0x22, .a = 0xff };
            try dvui.pathStroke(false, 3.0, .none, stroke_color);
        }

        const drag_state_changed = (prev_drag_state == null) != (maybe_drag_offset == null);

        const stopped_dragging = drag_state_changed and maybe_drag_offset == null;

        if (stopped_dragging) {
            if (edge_drag_end) |end| {
                const edge = if (end.kind == .input) .{
                    .source = edge_drag_start.?.socket,
                    .target = end,
                } else .{
                    .source = end,
                    .target = edge_drag_start.?.socket,
                };

                const valid_edge = edge.source.kind != edge.target.kind and edge.source.node_id != edge.target.node_id;
                if (valid_edge) {
                    // FIXME: why am I assumign edge_drag_start exists?
                    // TODO: maybe use unreachable instead of try?
                    try visual_graph.addEdge(
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

fn considerSocketForHover(icon_res: *const dvui.ButtonIconResult, socket: Socket) dvui.Point {
    const r = icon_res.icon.wd.rectScale().r;
    const socket_center = rectCenter(r);

    if (rectContainsMouse(r)) {
        const is_dragging = dvui.dragging(dvui.Point{ .x = 0, .y = 0 }) != null;

        if (is_dragging and edge_drag_start != null
        //
        and socket.kind != edge_drag_start.?.socket.kind
        // FIXME: for now not allowing trivial cyclic connections
        and socket.node_id != edge_drag_start.?.socket.node_id) {
            dvui.cursorSet(.crosshair);
            edge_drag_end = socket;
        }

        if (!is_dragging) {
            dvui.cursorSet(.crosshair);
            edge_drag_start = .{
                .pt = socket_center,
                .socket = socket,
            };
        }
    }
    return socket_center;
}

// TODO: remove need for id, it should be inside the node itself
fn renderNode(
    node: *const grappl.Node,
    socket_positions: *std.AutoHashMapUnmanaged(Socket, dvui.Point),
) !void {
    const root_id_extra: usize = @intCast(node.id);

    const position = if (visual_graph.node_data.get(node.id)) |viz_data| viz_data.position else dvui.Point{
        .x = @floatFromInt(node.position.x),
        .y = @floatFromInt(node.position.y),
    };

    const box = try dvui.box(
        @src(),
        .vertical,
        .{
            .rect = dvui.Rect{ .x = position.x, .y = position.y },
            .id_extra = root_id_extra,
            .debug = true,
            .margin = .{ .h = 5, .w = 5, .x = 5, .y = 5 },
            .padding = .{ .h = 5, .w = 5, .x = 5, .y = 5 },
            .background = true,
            .border = .{ .h = 1, .w = 1, .x = 1, .y = 1 },
            .corner_radius = .{ .h = 5, .w = 5, .x = 5, .y = 5 },
            .color_border = .{ .color = dvui.Color.black },
            //.max_size_content = dvui.Size{ .w = 300, .h = 600 },
        },
    );
    defer box.deinit();

    try dvui.label(@src(), "{s}", .{node.desc.name}, .{ .color_text = .{ .color = dvui.Color.black }, .font_style = .title_3 });

    var hbox = try dvui.box(@src(), .horizontal, .{});
    defer hbox.deinit();

    var inputs_vbox = try dvui.box(@src(), .vertical, .{});

    for (node.desc.getInputs(), node.inputs, 0..) |input_desc, *input, j| {
        var input_box = try dvui.box(@src(), .horizontal, .{ .id_extra = j });
        defer input_box.deinit();

        const socket = Socket{ .node_id = node.id, .kind = .input, .index = @intCast(j) };

        const icon_opts = dvui.Options{
            .min_size_content = .{ .h = 20, .w = 20 },
            .gravity_y = 0.5,
            .id_extra = j,
            .color_fill_hover = .{ .color = .{ .r = 0x99, .g = 0x99, .b = 0xff, .a = 0xff } },
            //
            .debug = true,
            .border = .{ .x = 1, .y = 1, .w = 1, .h = 1 },
            .color_border = .{ .color = .{ .b = 0xff, .a = 0xff } },
            .background = true,
        };

        const socket_point: dvui.Point = if (input_desc.kind.primitive == .exec) _: {
            const icon_res = try dvui.buttonIcon(@src(), "arrow_with_circle_right", entypo.arrow_with_circle_right, .{}, icon_opts);
            const socket_center = considerSocketForHover(&icon_res, socket);

            break :_ socket_center;
        } else _: {
            // FIXME: make non interactable/hoverable

            const icon_res = try dvui.buttonIcon(@src(), "circle", entypo.circle, .{}, icon_opts);
            const socket_center = considerSocketForHover(&icon_res, socket);

            // FIXME: report compiler bug
            // } else switch (i.kind.primitive.value) {
            //     grappl.primitive_types.i32_ => {
            if (input.* != .link) {
                // TODO: handle all possible types using switch or something
                var handled = false;

                inline for (.{ i32, i64, u32, u64, f32, f64 }) |T| {
                    const primitive_type = @field(grappl.primitive_types, @typeName(T) ++ "_");
                    if (input_desc.kind.primitive.value == primitive_type) {
                        const entry = try dvui.textEntryNumber(@src(), T, .{}, .{ .id_extra = j });
                        if (entry.enter_pressed and entry.value == .Valid)
                            input.* = .{ .value = .{
                                .number = if (@typeInfo(T) == .Int) @floatFromInt(entry.value.Valid) else @floatCast(entry.value.Valid),
                            } };
                        handled = true;
                    }
                }

                if (input_desc.kind.primitive.value == grappl.primitive_types.bool_ and input.* == .value) {
                    //node.inputs[j] = .{.literal}
                    if (input.* != .value or input.value != .bool) {
                        input.* = .{ .value = .{ .bool = false } };
                    }

                    std.debug.assert(input.*.value == .bool);
                    _ = try dvui.checkbox(@src(), &input.value.bool, null, .{ .id_extra = j });
                    handled = true;
                }

                if (!handled)
                    try dvui.label(@src(), "Unknown type: {s}", .{input_desc.kind.primitive.value.name}, .{ .color_text = .{ .color = dvui.Color.black }, .id_extra = j });
            }

            break :_ socket_center;
        };

        try socket_positions.put(gpa, socket, socket_point);

        _ = try dvui.label(@src(), "{s}", .{input_desc.name}, .{ .font_style = .heading, .color_text = .{ .color = dvui.Color.black }, .id_extra = j });
    }

    inputs_vbox.deinit();

    var outputs_vbox = try dvui.box(@src(), .vertical, .{});

    for (node.desc.getOutputs(), node.outputs, 0..) |output_desc, output, j| {
        var output_box = try dvui.box(@src(), .horizontal, .{ .id_extra = j });
        defer output_box.deinit();

        const socket = Socket{ .node_id = node.id, .kind = .output, .index = @intCast(j) };

        const icon_opts = dvui.Options{
            .min_size_content = .{ .h = 20, .w = 20 },
            .gravity_y = 0.5,
            .id_extra = j,
            //
            .debug = true,
            .border = .{ .x = 1, .y = 1, .w = 1, .h = 1 },
            .color_border = .{ .color = .{ .g = 0xff, .a = 0xff } },
            .background = true,
        };

        _ = output;
        _ = try dvui.label(@src(), "{s}", .{output_desc.name}, .{ .font_style = .heading, .color_text = .{ .color = dvui.Color.black }, .id_extra = j });

        const icon_res = if (output_desc.kind.primitive == .exec)
            try dvui.buttonIcon(@src(), "arrow_with_circle_right", entypo.arrow_with_circle_right, .{}, icon_opts)
        else
            try dvui.buttonIcon(@src(), "circle", entypo.circle, .{}, icon_opts);

        const socket_center = considerSocketForHover(&icon_res, socket);
        try socket_positions.put(gpa, socket, socket_center);
    }

    outputs_vbox.deinit();
}

var scroll_info = dvui.ScrollInfo{
    .horizontal = .auto,
    .vertical = .auto,
    //.velocity = dvui.Point{ .x = 1, .y = 1 },
    .viewport = dvui.Rect{ .w = 5000, .h = 5000 },
    // NOTE: updated by the graph
    .virtual_size = dvui.Size{ .w = 1000, .h = 1000 },
};

pub const VisualGraph = struct {
    pub const NodeData = struct {
        // TODO: remove grappl.Node.position
        position: dvui.Point,
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

    pub fn addNode(self: *@This(), alloc: std.mem.Allocator, kind: []const u8, is_entry: bool, force_node_id: ?grappl.NodeId, diag: ?*grappl.GraphBuilder.Diagnostic) !grappl.NodeId {
        const result = try self.graph.addNode(alloc, kind, is_entry, force_node_id, diag);
        // FIXME:
        // errdefer self.graph.removeNode(result);
        try self.formatGraphNaive(gpa); // FIXME: do this iteratively! don't reformat the whole thing...
        return result;
    }

    pub fn addEdge(self: *@This(), start_id: grappl.NodeId, start_index: u16, end_id: grappl.NodeId, end_index: u16, end_subindex: u16) !void {
        const result = try self.graph.addEdge(start_id, start_index, end_id, end_index, end_subindex);
        // FIXME: (note that if edge did any "replacing", that also needs to be restored!)
        // errdefer self.graph.removeEdge(result);
        // TODO:
        try self.formatGraphNaive(gpa); // FIXME: do this iteratively! don't reformat the whole thing...
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
                                .link => |v| v,
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
        const first_node = in_self.graph.entry orelse in_self.graph.nodes.map.getPtr(0) orelse return;

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
                    const node_size = dvui.Size{ .w = 350, .h = 150 };
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

fn updateScrollInfo() void {
    //grappl_graph.getSize();
}

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

    updateScrollInfo();

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

    var box1 = try dvui.box(@src(), .vertical, .{ .expand = .horizontal, .background = true });
    var t2 = try dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font_style = .title_4 });
    try t2.addText("Grappl Test Editor", .{});
    try t2.addText("Another\n", .{});
    try t2.addText("Another\n", .{});
    try t2.addText("Another\n", .{});
    try t2.addText("Another\n", .{});
    try t2.addText("Another\n", .{});
    try t2.addText("Another\n", .{});
    try t2.addText("Another\n", .{});
    t2.deinit();
    box1.deinit();

    const ctext = try dvui.context(@src(), .{ .expand = .both });
    defer ctext.deinit();

    context_menu_widget_id = ctext.wd.id;

    if (ctext.activePoint()) |cp| {
        try renderAddNodeMenu(cp, node_menu_filter);
    } else {
        node_menu_filter = null;
    }

    //var scroll = try dvui.scrollArea(@src(), .{ .horizontal = .auto }, .{ .expand = .both, .color_fill = .{ .name = .fill_window } });
    //defer scroll.deinit();

    var tl = try dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font_style = .title_4 });
    try tl.addText("Grappl Test Editor", .{});
    tl.deinit();
    if (try dvui.button(@src(), "Debug", .{}, .{})) {
        win.debug_window_show = true;
    }

    //if (!(std.math.approxEqAbs(f32, scroll_info.virtual_size.h, visual_graph.graph_bb.size().h, 0.1) and std.math.approxEqAbs(f32, scroll_info.virtual_size.w, visual_graph.graph_bb.size().w, 0.1))) {
    // this causes a refresh for some reason, nextVirtualSize is always 0 for some reason
    scroll_info.virtual_size = visual_graph.graph_bb.size();
    //}

    //scroll_info.viewport = visual_graph.graph_bb;

    var graph_area = try dvui.scrollArea(
        @src(),
        .{
            .scroll_info = &scroll_info,
            // FIXME: probably can remove?
            .horizontal = .auto,
        },
        .{ .expand = .both, .color_fill = .{ .name = .fill_window } },
    );
    defer graph_area.deinit();
    try renderGraph();

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
