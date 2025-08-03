//! Copyright 2024, Michael Belousov
//!

const std = @import("std");
const RaylibBackend = dvui.backend;

const dvui = @import("dvui");

const graphl = @import("graphl_core");
const App = @import("./native-app.zig");

const c = RaylibBackend.c;

// FIXME:
//const window_icon_png = @embedFile("zig-favicon.png");

const gpa = App.gpa;

var show_dialog_outside_frame: bool = false;

const vsync = true;
var scale_val: f32 = 1.0;

var transfer_buffer = std.mem.zeroes([std.heap.page_size_min]u8);

pub fn main() !void {
    // FIXME: mac keybindings?

    // init Raylib backend (creates OS window)
    // initWindow() means the backend calls CloseWindow for you in deinit()
    var backend = try RaylibBackend.initWindow(.{
        .gpa = gpa,
        .size = .{ .w = 800.0, .h = 600.0 },
        .vsync = vsync,
        .title = "Graphl IDE",
        //.icon = window_icon_png, // can also call setIconFromFileContent()
    });
    defer backend.deinit();
    backend.log_events = true;

    // init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{});
    defer win.deinit();


    var graphs: App.GraphsInitState = .{};
    try graphs.putNoClobber(gpa, "geometry", .{
        .name = "geometry",
        .fixed_signature = true,
        .nodes = .fromOwnedSlice(try gpa.dupe(App.NodeInitState, &.{
            .{
                .id = 1,
                .type_ = "Point",
                .inputs = _: {
                    var inputs: std.AutoHashMapUnmanaged(u16, App.InputInitState) = .{};
                    errdefer inputs.deinit(gpa);
                    try inputs.putNoClobber(gpa, 0, .{ .float = -2 });
                    try inputs.putNoClobber(gpa, 1, .{ .float = 0 });
                    try inputs.putNoClobber(gpa, 2, .{ .float = 0 });
                    break :_ inputs;
                },
            },
            .{
                .id = 2,
                .type_ = "Point",
                .inputs = _: {
                    var inputs: std.AutoHashMapUnmanaged(u16, App.InputInitState) = .{};
                    errdefer inputs.deinit(gpa);
                    try inputs.putNoClobber(gpa, 0, .{ .float = 2 });
                    try inputs.putNoClobber(gpa, 1, .{ .float = 0 });
                    try inputs.putNoClobber(gpa, 2, .{ .float = 0 });
                    break :_ inputs;
                },
            },
            .{
                .id = 3,
                .type_ = "Point",
                .inputs = _: {
                    var inputs: std.AutoHashMapUnmanaged(u16, App.InputInitState) = .{};
                    errdefer inputs.deinit(gpa);
                    try inputs.putNoClobber(gpa, 0, .{ .float = 1.5 });
                    try inputs.putNoClobber(gpa, 1, .{ .float = 1.5 });
                    try inputs.putNoClobber(gpa, 2, .{ .float = 1.5 });
                    break :_ inputs;
                },
            },
            .{
                .id = 4,
                .type_ = "Sphere",
                .inputs = _: {
                    var inputs: std.AutoHashMapUnmanaged(u16, App.InputInitState) = .{};
                    errdefer inputs.deinit(gpa);
                    try inputs.putNoClobber(gpa, 0, .{ .node = .{ .id = 0, .out_pin = 0 }});
                    try inputs.putNoClobber(gpa, 1, .{ .node = .{ .id = 1, .out_pin = 0 }});
                    try inputs.putNoClobber(gpa, 2, .{ .float = 1 });
                    try inputs.putNoClobber(gpa, 3, .{ .string = "FF4444" });
                    break :_ inputs;
                },
            },
            .{
                .id = 5,
                .type_ = "Box",
                .inputs = _: {
                    var inputs: std.AutoHashMapUnmanaged(u16, App.InputInitState) = .{};
                    errdefer inputs.deinit(gpa);
                    try inputs.putNoClobber(gpa, 0, .{ .node = .{ .id = 4, .out_pin = 0 }});
                    try inputs.putNoClobber(gpa, 1, .{ .node = .{ .id = 2, .out_pin = 0 }});
                    try inputs.putNoClobber(gpa, 2, .{ .node = .{ .id = 3, .out_pin = 0 }});
                    try inputs.putNoClobber(gpa, 3, .{ .string = "4444FF" });
                    break :_ inputs;
                },
            },
            .{
                .id = 6,
                .type_ = "return",
                .inputs = _: {
                    var inputs: std.AutoHashMapUnmanaged(u16, App.InputInitState) = .{};
                    errdefer inputs.deinit(gpa);
                    try inputs.putNoClobber(gpa, 0, .{ .node = .{ .id = 5, .out_pin = 0 }});
                    break :_ inputs;
                },
            },
        })),
        .parameters = &.{},
        .results = &.{},
    });

    try graphs.putNoClobber(gpa, "main", .{
        .name = "main",
        .fixed_signature = true,
        .nodes = .fromOwnedSlice(try gpa.dupe(App.NodeInitState, &.{
            .{
                .id = 1,
                .type_ = "geometry",
                .inputs = _: {
                    var inputs: std.AutoHashMapUnmanaged(u16, App.InputInitState) = .{};
                    errdefer inputs.deinit(gpa);
                    try inputs.putNoClobber(gpa, 0, .{ .node = .{ .id = 0, .out_pin = 0 }});
                    break :_ inputs;
                },
            },
            .{
                .id = 2,
                .type_ = "return",
                .inputs = _: {
                    var inputs: std.AutoHashMapUnmanaged(u16, App.InputInitState) = .{};
                    errdefer inputs.deinit(gpa);
                    try inputs.putNoClobber(gpa, 0, .{ .node = .{ .id = 1, .out_pin = 0 }});
                    break :_ inputs;
                },
            },
        })),
        .parameters = &.{},
        .results = &.{},
    });


    try App.init(.{
        .transfer_buffer = &transfer_buffer,
        .graphs = graphs,
        .user_funcs = &.{
            .{
                .id = 1,
                .node = .{
                    .name = "Box",
                    .inputs = try gpa.dupe(graphl.Pin, &.{
                        .{ .name = "", .kind = .{ .primitive = .exec } },
                        .{ .name = "center", .kind = .{ .primitive = .{ .value = graphl.nonprimitive_types.vec3 } } },
                        .{ .name = "radius", .kind = .{ .primitive = .{ .value = graphl.primitive_types.f64_ } } },
                        .{ .name = "color", .kind = .{ .primitive = .{ .value = graphl.primitive_types.string } } },
                    }),
                    .outputs = try gpa.dupe(graphl.Pin, &.{}),
                },
            },
            .{
                .id = 2,
                .node = .{
                    .name = "Sphere",
                    .inputs = try gpa.dupe(graphl.Pin, &.{
                        .{ .name = "", .kind = .{ .primitive = .exec } },
                        .{ .name = "position", .kind = .{ .primitive = .{ .value = graphl.nonprimitive_types.vec3 } } },
                        .{ .name = "dimensions", .kind = .{ .primitive = .{ .value = graphl.nonprimitive_types.vec3 } } },
                        .{ .name = "color", .kind = .{ .primitive = .{ .value = graphl.primitive_types.string } } },
                    }),
                    .outputs = try gpa.dupe(graphl.Pin, &.{}),
                },
            },
            .{
                .id = 3,
                .node = .{
                    // FIXME: replace with just using the vec3 node which should exist...
                    .name = "Point",
                    .inputs = try gpa.dupe(graphl.Pin, &.{
                        .{ .name = "x", .kind = .{ .primitive = .{ .value = graphl.primitive_types.f64_ } } },
                        .{ .name = "y", .kind = .{ .primitive = .{ .value = graphl.primitive_types.f64_ } } },
                        .{ .name = "z", .kind = .{ .primitive = .{ .value = graphl.primitive_types.f64_ } } },
                    }),
                    .outputs = try gpa.dupe(graphl.Pin, &.{
                        .{ .name = "", .kind = .{ .primitive = .{ .value = graphl.nonprimitive_types.vec3 } } },
                    }),
                },
            },
        },
        .menus = &.{
            .{
                .name = "Build",
                .submenus = &.{
                    .{
                        .name = "compile",
                        .on_click = &(struct { pub fn impl(_: ?*anyopaque, _: ?*anyopaque) void {
                            const graphlt = App.app.compileToGraphlt() catch |e| {
                                std.debug.print("graphlt compilation failed with '{}'", .{e});
                                return;
                            };
                            defer gpa.free(graphlt);
                            std.debug.print("graphlt:\n{s}\n", .{graphlt});
                            const wasm = App.app.compileToWasm() catch |e| {
                                std.debug.print("wasm compilation failed with '{}'", .{e});
                                return;
                            };
                            defer gpa.free(wasm);
                        } }.impl),
                    },
                },
            },
        },
    });
    defer App.deinit();

    // small fonts look bad on the web, so bump the default theme up
    var theme = win.themes.get("Adwaita Light").?;
    //win.themes.put("Adwaita Light", theme.fontSizeAdd(2)) catch {};
    theme = win.themes.get("Adwaita Dark").?;
    //win.themes.put("Adwaita Dark", theme.fontSizeAdd(2)) catch {};
    win.theme = win.themes.get("Adwaita Dark").?;
    //win.theme = win.themes.get("Adwaita Light").?;

    main_loop: while (true) {
        c.BeginDrawing();

        // Raylib does not support waiting with event interruption, so dvui
        // can't do variable framerate.  So can't call win.beginWait() or
        // win.waitTime().
        try win.begin(std.time.nanoTimestamp());

        // send all events to dvui for processing
        const quit = try backend.addAllEvents(&win);
        if (quit) break :main_loop;

        // if dvui widgets might not cover the whole window, then need to clear
        // the previous frame's render
        backend.clear();

        try App.frame();

        // marks end of dvui frame, don't call dvui functions after this
        // - sends all dvui stuff to backend for rendering, must be called before renderPresent()
        _ = try win.end(.{});

        // cursor management
        backend.setCursor(win.cursorRequested());

        // render frame to OS
        c.EndDrawing();

        // Example of how to show a dialog from another thread (outside of win.begin/win.end)
        if (show_dialog_outside_frame) {
            show_dialog_outside_frame = false;
            try dvui.dialog(@src(), .{}, .{ .window = &win, .modal = false, .title = "Dialog from Outside", .message = "This is a non modal dialog that was created outside win.begin()/win.end(), usually from another thread." });
        }
    }
}

test {
    std.testing.refAllDecls(App);
}
