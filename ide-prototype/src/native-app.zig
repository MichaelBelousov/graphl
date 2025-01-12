//! Copyright 2024, Michael Belousov
//!

const std = @import("std");
const builtin = @import("builtin");
const bytebox = @import("bytebox");

const dvui = @import("dvui");
comptime {
    std.debug.assert(dvui.backend_kind == .raylib);
}

const App = @import("./app.zig");

var app: App = .{};
var result_buffer = std.mem.zeroes([4096]u8);

pub fn init(in_init_opts: App.InitOptions) !void {
    // FIXME: should not destroy user input
    std.debug.assert(in_init_opts.result_buffer == null);
    var init_opts = in_init_opts;
    init_opts.result_buffer = &result_buffer;
    try App.init(&app, init_opts);
}

pub fn deinit() void {
    app.deinit();
}

pub fn frame() !void {
    try app.frame();
}

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

    _ = std.fmt.bufPrint(&result_buffer, "{}", .{results[0].I32}) catch {};
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
        std.log.err("error '{}', in onRequestLoadSource", .{err});
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

    try app.onReceiveLoadedSource(src);
}

// FIXME:
//const window_icon_png = @embedFile("zig-favicon.png");

// FIXME: merge with app allocator!
var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();
