//! Copyright 2024, Michael Belousov
//!

const std = @import("std");
const builtin = @import("builtin");
pub usingnamespace @import("graphl_core");

const dvui = @import("dvui");

const App = @import("./app.zig");

// FIXME: gross
pub var app: App = .{};
var result_buffer = std.mem.zeroes([4096]u8);

// TODO: using namespace?
pub const GraphsInitState = App.GraphsInitState;
pub const GraphInitState = App.GraphInitState;
pub const addParamToCurrentGraph = App.addParamToCurrentGraph;

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
    var file = try std.fs.createFileAbsolute("/tmp/compiler-native.wasm", .{});
    defer file.close();
    try file.writer().writeAll(wat);
    // TODO: run wasmtime or javascript SDK lol
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
