// TODO: rename to generic_main?

const std = @import("std");
const builtin = @import("builtin");

test {
    std.testing.refAllDeclsRecursive(@This());
}

// import to export these public functions
pub const sourceToGraph = @import("./source_to_graph.zig").sourceToGraph;
pub const graphToSource = @import("./graph_to_source.zig").graphToSource;
pub const readSrc = @import("./ide_json_gen.zig").readSrc;
