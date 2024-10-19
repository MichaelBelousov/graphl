const std = @import("std");
const WebBackend = @import("WebBackend");
usingnamespace WebBackend.wasm;

const dvui = @import("dvui");
const entypo = @import("dvui").entypo;
const Rect = dvui.Rect;

const grappl = @import("grappl_core");

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
        const plus_node = grappl_graph.env.makeNode(gpa, "+", grappl.ExtraIndex{ .index = 0 }) catch unreachable orelse unreachable;
        const plus_index = grappl_graph.addNode(gpa, plus_node, false, null, null) catch unreachable;
        const set_node = grappl_graph.env.makeNode(gpa, "set!", grappl.ExtraIndex{ .index = 0 }) catch unreachable orelse unreachable;
        const set_index = grappl_graph.addNode(gpa, set_node, false, null, null) catch unreachable;
        _ = grappl_graph.addEdge(plus_index, 0, set_index, 2, 0) catch unreachable;
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

const Socket = struct {
    node_id: grappl.NodeId,
    kind: enum(u1) { input, output },
    index: u32,
};

fn renderGraph() !void {
    // TODO: use link struct?
    var socket_positions = std.AutoHashMapUnmanaged(Socket, dvui.Rect){};
    defer socket_positions.deinit(gpa);

    // place nodes
    {
        var node_iter = grappl_graph.nodes.map.iterator();
        while (node_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            const node = entry.value_ptr.*;
            try renderNode(node_id, node, &socket_positions);
        }
    }

    // place edges
    {
        var node_iter = grappl_graph.nodes.map.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            for (node.inputs) |input| {
                switch (input) {
                    .link => |link| {
                        //link.target.node.position
                        _ = link;
                    },
                    else => {},
                }
            }

            const indices: []const u16 = &[_]u16{ 0, 1, 2, 0, 2, 3 };
            const vtx: []const dvui.Vertex = &[_]dvui.Vertex{
                .{ .pos = .{ .x = 100, .y = 150 }, .uv = .{ 0.0, 0.0 }, .col = .{} },
                .{ .pos = .{ .x = 200, .y = 150 }, .uv = .{ 1.0, 0.0 }, .col = .{ .g = 0, .b = 0, .a = 200 } },
                .{ .pos = .{ .x = 200, .y = 250 }, .uv = .{ 1.0, 1.0 }, .col = .{ .r = 0, .b = 0, .a = 100 } },
                .{ .pos = .{ .x = 100, .y = 250 }, .uv = .{ 0.0, 1.0 }, .col = .{ .r = 0, .g = 0 } },
            };
            backend.drawClippedTriangles(null, vtx, indices, null);
        }
    }
}

// TODO: remove need for id, it should be inside the node itself
fn renderNode(
    node_id: grappl.NodeId,
    node: grappl.Node,
    socket_positions: *std.AutoHashMapUnmanaged(Socket, dvui.Rect),
) !void {
    //dvui.parentGet().rectFor();
    const box = try dvui.boxEqual(
        @src(),
        .vertical,
        .{
            //.min_size_content =
            .rect = Rect{ .x = @floatFromInt(200 + node_id * 320), .y = 0 },
            .id_extra = @intCast(node_id),
            //.color_fill = .{ .color = try dvui.Color.fromHex(@as(*const [7]u8, @ptrCast(&"#ff0000"[0])).*) },
            .debug = true,
            .margin = .{ .h = 5, .w = 5, .x = 5, .y = 5 },
            .padding = .{ .h = 5, .w = 5, .x = 5, .y = 5 },
            .border = .{ .h = 1, .w = 1, .x = 1, .y = 1 },
            .corner_radius = .{ .h = 5, .w = 5, .x = 5, .y = 5 },
            .color_border = .{ .color = dvui.Color.black },
        },
    );
    defer box.deinit();

    try dvui.label(@src(), "{s}", .{node.desc.name}, .{ .color_text = .{ .color = dvui.Color.black }, .font_style = .heading });

    var hbox = try dvui.box(@src(), .horizontal, .{});
    defer hbox.deinit();

    var input_vbox = try dvui.box(@src(), .vertical, .{});
    for (node.desc.getInputs(), node.inputs, 0..) |input_desc, input, j| {
        // FIXME: inputs should have their own name!

        const icon_opts = dvui.Options{
            .min_size_content = .{ .h = 20, .w = 20 },
            .gravity_y = 0.5,
            .id_extra = j,
            .color_fill_hover = .{ .color = .{ .r = 0x99, .g = 0x99, .b = 0xff, .a = 0xff } },
        };

        _ = try dvui.label(@src(), "{s}", .{input_desc.name}, .{ .color_text = .{ .color = dvui.Color.black }, .id_extra = j });
        if (input_desc.kind.primitive == .exec) {
            const icon = try dvui.icon(@src(), "arrow_with_circle_right", entypo.arrow_with_circle_right, icon_opts);
            try socket_positions.put(gpa, .{ .node_id = node_id, .kind = .input, .index = j }, icon.wd.contentRect());
            // FIXME: report compiler bug
            // } else switch (i.kind.primitive.value) {
            //     grappl.primitive_types.i32_ => {
        } else if (input_desc.kind.primitive.value == grappl.primitive_types.i32_) {
            const result = try dvui.textEntryNumber(@src(), i32, .{}, .{ .id_extra = j });
            // TODO:
            _ = result;
            //node.inputs[j] = .{.literal}
            //
            // TODO: inline for (.{"f64_", "i32_"}) |name| {
            //  @field(grappl.primitive_types, name)
            // }
        } else if (input_desc.kind.primitive.value == grappl.primitive_types.f64_) {
            const result = try dvui.textEntryNumber(@src(), f64, .{}, .{ .id_extra = j });
            // TODO:
            _ = result;
            //node.inputs[j] = .{.literal}
        } else if (input_desc.kind.primitive.value == grappl.primitive_types.bool_ and input == .value) {
            var val = false;
            const result = try dvui.checkbox(@src(), &val, null, .{ .id_extra = j });
            // TODO:
            _ = result;
            //node.inputs[j] = .{.literal}
        } else {
            try dvui.label(@src(), "Unknown type: {s}", .{input_desc.kind.primitive.value.name}, .{ .color_text = .{ .color = dvui.Color.black }, .id_extra = j });
        }
    }
    input_vbox.deinit();

    var output_vbox = try dvui.box(@src(), .vertical, .{});
    for (node.desc.getOutputs(), node.outputs, 0..) |output_desc, output, j| {
        const icon_opts = dvui.Options{
            .min_size_content = .{ .h = 20, .w = 20 },
            .gravity_y = 0.5,
            .id_extra = j,
        };

        _ = output;
        _ = try dvui.label(@src(), "{s}", .{output_desc.name}, .{ .color_text = .{ .color = dvui.Color.black }, .id_extra = j });
        if (output_desc.kind.primitive == .exec) {
            _ = try dvui.icon(@src(), "arrow_with_circle_right", entypo.arrow_with_circle_right, icon_opts);
        } else {
            _ = try dvui.icon(@src(), "circle", entypo.circle, icon_opts);
        }
    }
    output_vbox.deinit();
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

    const ctext = try dvui.context(@src(), .{ .expand = .both });
    defer ctext.deinit();

    if (ctext.activePoint()) |cp| {
        var fw2 = try dvui.floatingMenu(@src(), Rect.fromPoint(cp), .{});
        defer fw2.deinit();

        {
            var iter = grappl_graph.env.nodes.keyIterator();
            var i: u32 = 0;
            while (iter.next()) |node_name| {
                if ((try dvui.menuItemLabel(@src(), node_name.*, .{}, .{ .expand = .horizontal, .id_extra = i })) != null) {
                    const node = grappl_graph.env.makeNode(gpa, node_name.*, grappl.ExtraIndex{ .index = 0 }) catch unreachable orelse unreachable;
                    // TODO: use diagnostic
                    const node_id = try grappl_graph.addNode(gpa, node, false, null, null);
                    _ = node_id;
                    fw2.close();
                }
                i += 1;
            }
        }

        if ((try dvui.menuItemLabel(@src(), "Close Menu", .{}, .{ .expand = .horizontal })) != null) {
            fw2.close();
        }
    }

    var scroll = try dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = .{ .name = .fill_window } });
    defer scroll.deinit();

    var tl = try dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font_style = .title_4 });
    try tl.addText("Grappl Test Editor", .{});
    tl.deinit();

    var tl2 = try dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
    try tl2.format(
        \\Graph below
        \\Hello graph!
        \\Man how will I use Monaco with this?
        \\
        \\backend: {s}
        \\
    , .{backend.about()}, .{});
    tl2.deinit();

    if (try dvui.button(@src(), "Reset Scale", .{}, .{})) {
        new_content_scale = orig_content_scale;
    }

    const label = if (dvui.Examples.show_demo_window) "Hide Demo Window" else "Show Demo Window";
    if (try dvui.button(@src(), label, .{}, .{})) {
        dvui.Examples.show_demo_window = !dvui.Examples.show_demo_window;
    }

    // look at demo() for examples of dvui widgets, shows in a floating window
    try dvui.Examples.demo();

    try renderGraph();

    if (new_content_scale) |ns| {
        win.content_scale = ns;
    }
}
