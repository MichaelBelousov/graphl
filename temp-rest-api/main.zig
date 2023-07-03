const std = @import("std");
const testing = std.testing;

const Slice = extern struct {
    ptr: [*]const u8,
    len: usize,

    fn from_slice(slice: []const u8) @This() {
        return @This(){ .ptr = slice.ptr, .len = slice.len };
    }
};

/// call c free on result
export fn graph_to_source(graph_json: Slice) Slice {
    _ = graph_json;
    return Slice.from_slice("");
}

/// call c free on result
export fn source_to_graph(source: Slice) Slice {
    _ = source;
    return Slice.from_slice("");
}

test "basic add functionality" {
    try testing.expectEqualStrings(source_to_graph(""), "");
    try testing.expectEqualStrings(graph_to_source(""), "");
}
