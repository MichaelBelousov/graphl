const std = @import("std");
const builtin = @import("builtin");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const testing = std.testing;

const ide_json_gen = @import("./ide_json_gen.zig");

// FIXME use wasm known memory limits or something
const global_alloc = @import("./common.zig").global_alloc;

test {
    _ = @import("./graph_to_source.zig");
    _ = @import("./source_to_graph.zig");
    _ = @import("./nodes/builtin.zig");
}

const src2graph = @import("./source_to_graph.zig");
const graph2src = @import("./graph_to_source.zig");

/// user must free
pub export fn grappl_graph_to_source(in_src: [*:0]const u8, out_status: ?*c_int) [*:0]const u8 {
    if (out_status) |s| s.* = 0;

    const src = in_src[0..std.mem.len(in_src)];

    var diagnostic: graph2src.GraphToSourceDiagnostic = .None;

    // TODO: use function that allocates with null terminator
    const out = graph2src.graphToSource(src, &diagnostic) catch |e| {
        if (out_status) |s| s.* = @intFromError(e);
        // FIXME: can't free this pointer so maybe better to crash with unreachable
        return std.fmt.allocPrintZ(global_alloc, "graphToSource error:\n{}\n", .{diagnostic}) catch "OutOfMemory trying to format error";
    };
    defer global_alloc.free(out);

    return global_alloc.dupeZ(u8, out) catch |e| {
        if (out_status) |s| s.* = @intFromError(e);
        return "";
    };
}

/// user must free
pub export fn grappl_source_to_graph(in_src: [*:0]const u8, out_status: ?*c_int) [*:0]const u8 {
    if (out_status) |s| s.* = 0;

    const src = in_src[0..std.mem.len(in_src)];

    // TODO: use function that allocates with null terminator
    const out = src2graph.sourceToGraph(src) catch |e| {
        if (out_status) |s| s.* = @intFromError(e);
        return;
    };
    defer global_alloc.free(out);

    return global_alloc.dupeZ(u8, out) catch |e| {
        if (out_status) |s| s.* = @intFromError(e);
        return "";
    };
}
