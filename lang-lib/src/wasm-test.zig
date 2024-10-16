const std = @import("std");
const t = std.testing;
const JsGraphBuilder = @import("../src/main.zig").JsGraphBuilder;

//pub fn main() void {
test "wasm-test-entry" {
    var g = try JsGraphBuilder.init(t.allocator);
    defer g.deinit(t.allocator);

    const entry_index = try g.addNode(t.allocator, try g.makeNode(t.allocator, "CustomTickEntry"), true);
    const plus_index = try g.addNode(t.allocator, try g.makeNode(t.allocator, "+"), false);
    const actor_loc_index = try g.addNode(t.allocator, try g.makeNode(t.allocator, "#GET#actor-location"), false);
    const set_index = try g.addNode(t.allocator, try g.makeNode(t.allocator, "set!"), false);

    try g.addEdge(actor_loc_index, 0, plus_index, 0);
    try g.addFloatLiteral(plus_index, 1, 4.0);
    try g.addEdge(entry_index, 0, set_index, 0);
    try g.addSymbolLiteral(set_index, 1, "x");
    try g.addEdge(plus_index, 0, set_index, 2);

    const src = try g.compile(t.allocator);

    std.debug.print("{s}\n", .{src});
}
