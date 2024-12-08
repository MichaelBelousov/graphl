//! Copyright 2024, Michael Belousov
//!

const std = @import("std");
const builtin = @import("builtin");
const RaylibBackend = dvui.backend;

const dvui = @import("dvui");
comptime {
    std.debug.assert(dvui.backend_kind == .raylib);
}

const app = @import("./app.zig");

const c = RaylibBackend.c;

export fn onExportCurrentSource(ptr: ?[*]const u8, len: usize) void {
    std.debug.print("onExportCurrentSource:\n{s}\n", .{ptr.?[0..len]});
}

export fn onExportCompiled(ptr: ?[*]const u8, len: usize) void {
    std.debug.print("onExportCompiled:\n{s}\n", .{ptr.?[0..len]});
}

export fn runCurrentWat(ptr: ?[*]const u8, len: usize) void {
    std.debug.print("runCurrentWat:\n{s}\n", .{ptr.?[0..len]});
}

export fn onClickReportIssue() void {}

export fn onRequestLoadSource() void {}

// FIXME:
//const window_icon_png = @embedFile("zig-favicon.png");

// FIXME: merge with app allocator!
var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

var show_dialog_outside_frame: bool = false;

const vsync = true;
var scale_val: f32 = 1.0;

pub fn main() !void {
    defer _ = gpa_instance.deinit();

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

    try app.init();
    defer app.deinit();

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

        try app.frame();

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
            try dvui.dialog(@src(), .{ .window = &win, .modal = false, .title = "Dialog from Outside", .message = "This is a non modal dialog that was created outside win.begin()/win.end(), usually from another thread." });
        }
    }
}
