//! Copyright 2024, Michael Belousov
//!

const std = @import("std");
const builtin = @import("builtin");
const RaylibBackend = dvui.backend;
const bytebox = @import("bytebox");

const dvui = @import("dvui");
comptime {
    std.debug.assert(dvui.backend_kind == .raylib);
}

const app = @import("./app.zig");

const c = RaylibBackend.c;

export fn onExportCurrentSource(ptr: ?[*]const u8, len: usize) void {
    _onExportCurrentSource((ptr orelse @panic("bad onExportCurrentSource"))[0..len]) catch |err| {
        std.log.err("error '{}', in onExportCurrentSource", .{err});
        return;
    };
}

fn _onExportCurrentSource(src: []const u8) !void {
    const path = try dvui.dialogNativeFileSave(gpa, .{
        .path = "project.scm",
        .title = "Export Graphlt",
    }) orelse return;
    defer gpa.free(path);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    try file.writeAll(src);
}

export fn onExportCompiled(ptr: ?[*]const u8, len: usize) void {
    _onExportCompiled((ptr orelse @panic("bad onExportCompiled"))[0..len]) catch |err| {
        std.log.err("error '{}', in onExportCompiled", .{err});
        return;
    };
}

fn _onExportCompiled(compiled: []const u8) !void {
    const path = try dvui.dialogNativeFileSave(gpa, .{
        .path = "compiled.wat",
        .title = "Export WebAssembly Text",
    }) orelse return;
    defer gpa.free(path);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    try file.writeAll(compiled);
}

export fn runCurrentWat(ptr: ?[*]const u8, len: usize) void {
    _runCurrentWat((ptr orelse unreachable)[0..len]) catch |err| {
        std.log.err("error '{}', in runCurrentWat", .{err});
        return;
    };
}

fn _runCurrentWat(wat: []const u8) !void {
    var tmp_dir = try std.fs.openDirAbsolute("/tmp", .{});
    defer tmp_dir.close();

    var dbg_file = try tmp_dir.createFile("compiler-test.wat", .{});
    defer dbg_file.close();

    try dbg_file.writeAll(wat);

    const wat2wasm_run = try std.process.Child.run(.{
        .allocator = gpa,
        .argv = &.{
            "wat2wasm",
            "/tmp/compiler-test.wat",
            "-o",
            "/tmp/compiler-test.wasm",
        },
    });
    defer gpa.free(wat2wasm_run.stdout);
    defer gpa.free(wat2wasm_run.stderr);
    if (!std.meta.eql(wat2wasm_run.term, .{ .Exited = 0 })) {
        std.debug.print("wat2wasm exited with {any}:\n{s}\n", .{ wat2wasm_run.term, wat2wasm_run.stderr });
        return error.FailTest;
    }

    var dbg_wasm_file = try tmp_dir.openFile("compiler-test.wasm", .{});
    defer dbg_wasm_file.close();
    var buff: [65536]u8 = undefined;
    const wasm_data_size = try dbg_wasm_file.readAll(&buff);

    const wasm_data = buff[0..wasm_data_size];

    const module_def = try bytebox.createModuleDefinition(gpa, .{});
    defer module_def.destroy();

    try module_def.decode(wasm_data);

    const module_instance = try bytebox.createModuleInstance(.Stack, module_def, gpa);
    defer module_instance.destroy();

    const Local = struct {
        fn nullHostFunc(user_data: ?*anyopaque, _module: *bytebox.ModuleInstance, _params: [*]const bytebox.Val, _returns: [*]bytebox.Val) void {
            _ = user_data;
            _ = _module;
            _ = _params;
            _ = _returns;
        }
    };

    var imports = try bytebox.ModuleImportPackage.init("env", null, null, gpa);
    defer imports.deinit();

    inline for (&.{
        .{ "callUserFunc_code_R", &.{ .I32, .I32, .I32 }, &.{} },
        .{ "callUserFunc_code_R_string", &.{ .I32, .I32, .I32 }, &.{.I32} },
        .{ "callUserFunc_string_R", &.{ .I32, .I32, .I32 }, &.{} },
        .{ "callUserFunc_R", &.{.I32}, &.{} },
        .{ "callUserFunc_i32_R", &.{ .I32, .I32 }, &.{} },
        .{ "callUserFunc_i32_R_i32", &.{ .I32, .I32 }, &.{.I32} },
        .{ "callUserFunc_i32_i32_R_i32", &.{ .I32, .I32, .I32 }, &.{.I32} },
        .{ "callUserFunc_bool_R", &.{ .I32, .I32 }, &.{} },
    }) |import_desc| {
        const name, const params, const results = import_desc;
        try imports.addHostFunction(name, params, results, Local.nullHostFunc, null);
    }

    try module_instance.instantiate(.{
        .imports = &.{imports},
    });

    const handle = try module_instance.getFunctionHandle("main");

    const args = [_]bytebox.Val{};
    var results = [_]bytebox.Val{bytebox.Val{ .I32 = 0 }};
    results[0] = bytebox.Val{ .I32 = 0 };
    try module_instance.invoke(handle, &args, &results, .{});

    _ = std.fmt.bufPrint(&app.result_buffer, "{}", .{results[0].I32}) catch {};
    dvui.refresh(null, @src(), null);
}

export fn onClickReportIssue() void {
    _ = std.process.Child.run(.{
        .allocator = gpa,
        .argv = &.{
            switch (builtin.os.tag) {
                .windows => "cmd",
                .linux => "xdg-open",
                .macos => "open",
                else => @compileError("unsupported platform"),
            },
            "https://docs.google.com/forms/d/e/1FAIpQLSf2dRcS7Nrv4Ut9GGmxIDVuIpzYnKR7CyHBMUkJQwdjenAXAA/viewform",
        },
    }) catch |err| {
        std.log.err("error '{}', in onClickReportIssue", .{err});
        return;
    };
}

export fn onRequestLoadSource() void {
    _onRequestLoadSource() catch |err| {
        std.log.err("error '{}', in onClickReportIssue", .{err});
        return;
    };
}

fn _onRequestLoadSource() !void {
    const path = try dvui.dialogNativeFileOpen(gpa, .{
        .path = "project.scm",
        .title = "Import Graphlt",
    }) orelse return;
    defer gpa.free(path);

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const src = try file.readToEndAlloc(gpa, 1 * 1024 * 1024);

    app.onReceiveLoadedSource(src.ptr, src.len);
}

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

test {
    std.testing.refAllDecls(app);
}
