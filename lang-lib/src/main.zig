// TODO: rename to generic_main?

const std = @import("std");
const builtin = @import("builtin");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const testing = std.testing;

const ide_json_gen = @import("./ide_json_gen.zig");

const global_alloc = @import("./common.zig").global_alloc;

test {
    std.testing.refAllDeclsRecursive(@This());
}

// import to export these public functions
pub usingnamespace @import("./source_to_graph.zig");
pub usingnamespace @import("./graph_to_source.zig");

pub fn readSrc(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    var page_writer = try PageWriter.init(a);
    defer page_writer.deinit();
    try ide_json_gen.readSrc(a, src, page_writer.writer());
    // FIXME: leak
    return try page_writer.concat(a);
}
