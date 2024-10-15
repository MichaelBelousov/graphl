// TODO: rename to zigar_main

const std = @import("std");
const builtin = @import("builtin");

test {
    std.testing.refAllDeclsRecursive(@This());
}

// import to export these public functions
pub const sourceToGraph = @import("./source_to_graph.zig").sourceToGraph;
pub const graphToSource = @import("./graph_to_source.zig").graphToSource;
pub const readSrc = @import("./ide_json_gen.zig").readSrc;

const GraphBuilder = @import("./graph_to_source.zig").GraphBuilder;
const NodeId = @import("./graph_to_source.zig").NodeId;
const IndexedNode = @import("./common.zig").GraphTypes.Node;
const ExtraIndex = @import("./common.zig").ExtraIndex;
const Env = @import("./nodes/builtin.zig").Env;
const NodeDesc = @import("./nodes/builtin.zig").NodeDesc;
const Value = @import("./nodes/builtin.zig").Value;

pub const JsGraphBuilder = struct {
    // erase type so zigar doesn't complain
    _inner: [@sizeOf(GraphBuilder)]u8 align(@alignOf(GraphBuilder)),

    fn inner(self: *@This()) *GraphBuilder {
        return @ptrCast(&self._inner[0]);
    }

    pub fn init(a: std.mem.Allocator) !@This() {
        const env = try Env.initDefault(a);
        var result = @This(){ ._inner = undefined };
        result.inner().* = try GraphBuilder.init(a, env);
        return result;
    }

    pub fn makeNode(self: *@This(), a: std.mem.Allocator, kind: []const u8) !IndexedNode {
        return try self.inner().env.makeNode(a, kind, ExtraIndex{ .index = 0 }) orelse error.UnknownNodeType;
    }

    pub fn addNode(self: *@This(), a: std.mem.Allocator, node: IndexedNode, is_entry: bool) !NodeId {
        return self.inner().addNode(a, node, is_entry, null, null);
    }

    pub fn addEdge(self: *@This(), source_id: NodeId, src_out_pin: u32, target_id: NodeId, target_in_pin: u32) !void {
        return try self.inner().addEdge(source_id, src_out_pin, target_id, target_in_pin, 0);
    }

    pub fn addBoolLiteral(self: *@This(), source_id: NodeId, src_in_pin: u32, value: bool) !void {
        return try self.inner().addLiteralInput(source_id, src_in_pin, 0, Value{ .bool = value });
    }

    pub fn addFloatLiteral(self: *@This(), source_id: NodeId, src_in_pin: u32, value: f64) !void {
        return try self.inner().addLiteralInput(source_id, src_in_pin, 0, Value{ .number = value });
    }

    pub fn addStringLiteral(self: *@This(), source_id: NodeId, src_in_pin: u32, value: []const u8) !void {
        return try self.inner().addLiteralInput(source_id, src_in_pin, 0, Value{ .string = value });
    }

    pub fn addSymbolLiteral(self: *@This(), source_id: NodeId, src_in_pin: u32, value: []const u8) !void {
        return try self.inner().addLiteralInput(source_id, src_in_pin, 0, Value{ .symbol = value });
    }

    pub fn compile(self: *@This(), a: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(a);
        defer buffer.deinit();

        const sexp = try self.inner().compile(a);
        // FIXME: does this even work?
        defer sexp.deinit(a);

        _ = try sexp.write(buffer.writer());

        return buffer.toOwnedSlice();
    }
};

comptime {
    std.debug.assert(@alignOf(GraphBuilder) == @alignOf(JsGraphBuilder));
}
