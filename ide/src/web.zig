//! Copyright 2024, Michael Belousov
//!

const std = @import("std");
const builtin = @import("builtin");
const WebBackend = dvui.backend;
comptime {
    std.debug.assert(@hasDecl(WebBackend, "WebBackend"));
}
usingnamespace WebBackend.wasm;

const dvui = @import("dvui");

const app = @import("./web-app.zig");


pub const dvui_app: dvui.App = .{ .initFn = app_init, .frameFn = app_frame, .deinitFn = app_deinit,
    .config = .{ .options = .{
        .size = .{ .w = 100, .h = 100 },
        .min_size = null,
        .max_size = null,
        .title = "graphl-ide",
        //icon: ?[]const u8 = null,
    } },
};

pub const main = dvui.App.main;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

// // var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
// // const gpa = gpa_instance.allocator();
// //pub const gpa = app.gpa;
// pub const gpa = std.heap.wasm_allocator;

fn app_init(win: *dvui.Window) void {
    app.init() catch |e| {
        std.log.err("App failed to init ({!})", .{e});
    };

    // // small fonts look bad on the web, so bump the default theme up
    var theme = win.themes.get("Adwaita Light").?;
    //win.themes.put("Adwaita Light", theme.fontSizeAdd(2)) catch {};
    theme = win.themes.get("Adwaita Dark").?;
    // //win.themes.put("Adwaita Dark", theme.fontSizeAdd(2)) catch {};
    win.theme = win.themes.get("Adwaita Dark").?;
    // //win.theme = win.themes.get("Adwaita Light").?;

    //orig_content_scale = WebBackend.win.content_scale;
}

fn app_deinit() void {
    app.deinit();
}

fn app_frame() !dvui.App.Result {
    // var new_content_scale: ?f32 = null;
    // var old_dist: ?f32 = null;
    // for (dvui.events()) |*e| {
    //     if (e.evt == .mouse and (e.evt.mouse.button == .touch0 or e.evt.mouse.button == .touch1)) {
    //         const idx: usize = if (e.evt.mouse.button == .touch0) 0 else 1;
    //         switch (e.evt.mouse.action) {
    //             .press => {
    //                 touchPoints[idx] = e.evt.mouse.p;
    //             },
    //             .release => {
    //                 touchPoints[idx] = null;
    //             },
    //             .motion => {
    //                 if (touchPoints[0] != null and touchPoints[1] != null) {
    //                     e.handled = true;
    //                     var dx: f32 = undefined;
    //                     var dy: f32 = undefined;

    //                     if (old_dist == null) {
    //                         dx = touchPoints[0].?.x - touchPoints[1].?.x;
    //                         dy = touchPoints[0].?.y - touchPoints[1].?.y;
    //                         old_dist = @sqrt(dx * dx + dy * dy);
    //                     }

    //                     touchPoints[idx] = e.evt.mouse.p;

    //                     dx = touchPoints[0].?.x - touchPoints[1].?.x;
    //                     dy = touchPoints[0].?.y - touchPoints[1].?.y;
    //                     const new_dist: f32 = @sqrt(dx * dx + dy * dy);

    //                     new_content_scale = @max(0.1, WebBackend.win.content_scale * new_dist / old_dist.?);
    //                 }
    //             },
    //             else => {},
    //         }
    //     }
    // }

    try app.frame();

    // if (new_content_scale) |ns| {
    //     WebBackend.win.content_scale = ns;
    // }
    //
    return .ok;
}
