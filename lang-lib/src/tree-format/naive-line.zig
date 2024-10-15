//! naive-line tree formatting algorithm
//! just put everything in a line...
//! OR let's just keep adding things in tree direction, e.g.

const std = @import("std");
const IndexedNode = @import("./common").GraphTypes.Node;

const Pt2 = struct {
    x: i64 = 0,
    y: i64 = 0,
};

const NaiveGraphFormat = struct {
    pub fn format(a: std.mem.Allocator, nodes: []IndexedNode) []Pt2 {
        const result = a.alloc(Pt2, nodes.len);
        for (result, 0..) |*r, i| r.* = Pt2{ .x = 100 * i, .y = 0 };
    }
};
