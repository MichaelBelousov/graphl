const std = @import("std");
const WebBackend = @import("WebBackend");
const grappl = @import("grappl_core");
usingnamespace WebBackend.wasm;

const dvui = @import("dvui");
const Rect = dvui.Rect;

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

const zig_favicon = @embedFile("src/zig-favicon.png");

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

    // const indices: []const u16 = &[_]u16{ 0, 1, 2, 0, 2, 3 };
    // const vtx: []const dvui.Vertex = &[_]dvui.Vertex{
    //     .{ .pos = .{ .x = 100, .y = 150 }, .uv = .{ 0.0, 0.0 }, .col = .{} },
    //     .{ .pos = .{ .x = 200, .y = 150 }, .uv = .{ 1.0, 0.0 }, .col = .{ .g = 0, .b = 0, .a = 200 } },
    //     .{ .pos = .{ .x = 200, .y = 250 }, .uv = .{ 1.0, 1.0 }, .col = .{ .r = 0, .b = 0, .a = 100 } },
    //     .{ .pos = .{ .x = 100, .y = 250 }, .uv = .{ 0.0, 1.0 }, .col = .{ .r = 0, .g = 0 } },
    // };
    // backend.drawClippedTriangles(null, vtx, indices, null);

    const end_micros = try win.end(.{});

    backend.setCursor(win.cursorRequested());
    backend.setOSKPosition(win.OSKRequested());

    const wait_event_micros = win.waitTime(end_micros, null);
    return @intCast(@divTrunc(wait_event_micros, 1000));
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

    const ctext = try dvui.context(@src(), .{ .expand = .horizontal });
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
    const lorem = "Grappl Test Editor";
    try tl.addText(lorem, .{});
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

    {
        var node_iter = grappl_graph.nodes.map.iterator();
        while (node_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            const node = entry.value_ptr.*;
            try dvui.label(@src(), "{s}", .{node.desc.name}, .{ .color_text = .{ .color = dvui.Color.white }, .id_extra = @intCast(node_id) });
        }
    }

    if (new_content_scale) |ns| {
        win.content_scale = ns;
    }
}
