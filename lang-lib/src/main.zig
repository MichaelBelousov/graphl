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

// import to export these public functions
pub const source_to_graph = @import("./source_to_graph.zig");
pub const graph_to_source = @import("./graph_to_source.zig");

fn alloc_string(byte_count: usize) callconv(.C) [*:0]u8 {
    return (global_alloc.allocSentinel(u8, byte_count, 0) catch |e| return std.debug.panic("alloc error: {}", .{e})).ptr;
}

fn free_string(str: [*:0]u8) callconv(.C) void {
    return global_alloc.free(str[0..std.mem.len(str)]);
}

export fn readSrc(src: [*:0]const u8, in_status: ?*c_int) [*:0]const u8 {
    var ignored_status: c_int = 0;
    const out_status = in_status orelse &ignored_status;

    var page_writer = PageWriter.init(std.heap.page_allocator) catch {
        out_status.* = 1;
        return "Error: allocation err";
    };
    defer page_writer.deinit();

    ide_json_gen.readSrc(global_alloc, src[0..std.mem.len(src)], page_writer.writer()) catch {
        out_status.* = 1;
        return "Error: parse error";
    };

    page_writer.writer().writeByte(0) catch {
        out_status.* = 1;
        return "Error: write error";
    };

    // FIXME: leak
    return @as([*:0]const u8, @ptrCast((page_writer.concat(global_alloc) catch {
        out_status.* = 1;
        return "Error: alloc concat error";
    }).ptr));
}

// TODO: only export in wasi
pub fn main() void {}

comptime {
    if (builtin.target.cpu.arch == .wasm32) {
        @export(alloc_string, .{ .name = "alloc_string", .linkage = .strong });
        @export(free_string, .{ .name = "free_string", .linkage = .strong });
    }
}
