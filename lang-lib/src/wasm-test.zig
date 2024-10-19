const std = @import("std");
const t = std.testing;
const GraphTypes = @import("./common.zig").GraphTypes;
const JsGraphBuilder = @import("./main.zig").JsGraphBuilder;
const alloc = @import("./main.zig").alloc;

//pub fn main() void {
test "wasm-test-entry" {
    var g = try JsGraphBuilder.init();
    defer g.deinit();

    const entry_node = try g.makeNode("CustomTickEntry");
    const plus_node = try g.makeNode("+");
    const actor_loc_node = try g.makeNode("#GET#actor-location");
    const set_node = try g.makeNode("set!");

    const entry_index = try g.addNode(entry_node, true);
    const plus_index = try g.addNode(plus_node, false);
    const actor_loc_index = try g.addNode(actor_loc_node, false);
    const set_index = try g.addNode(set_node, false);

    try g.addEdge(actor_loc_index, 0, plus_index, 0);
    try g.addFloatLiteral(plus_index, 1, 4.0);
    try g.addEdge(entry_index, 0, set_index, 0);
    try g.addSymbolLiteral(set_index, 1, "x");
    try g.addEdge(plus_index, 0, set_index, 2);

    const src = try g.compile();
    defer alloc.free(src);

    std.debug.print("input align={}\n", .{@alignOf(GraphTypes.Input)});
    std.debug.print("output align={}\n", .{@alignOf(GraphTypes.Output)});
    std.debug.print("{s}\n", .{src});
}
