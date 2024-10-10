// TODO: rename to generic_main?

const std = @import("std");
const builtin = @import("builtin");

test {
    std.testing.refAllDeclsRecursive(@This());
}

// import to export these public functions
pub usingnamespace @import("./source_to_graph.zig");
pub usingnamespace @import("./graph_to_source.zig");
pub usingnamespace @import("./ide_json_gen.zig");
