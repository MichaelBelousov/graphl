const std = @import("std");
const io = std.io;
const testing = std.testing;
const json = std.json;

//var alloc = (std.heap.GeneralPurposeAllocator(.{}){}).allocator;

// TODO: give better name... C slice?
const Slice = extern struct {
    ptr: [*]const u8,
    len: usize,

    fn from_zig(slice: []const u8) @This() {
        return @This(){ .ptr = slice.ptr, .len = slice.len };
    }

    fn to_zig(self: @This()) []const u8 {
        return self.ptr[0..self.len];
    }
};

fn Result(comptime R: type, comptime E: type) type {
    return extern union {
        ok: R,
        err: E,
    };
}

const Loc = extern struct {
    /// 1-indexed
    line: usize,
    /// 1-indexed
    col: usize,
    index: usize,
};

const SourceToGraphErr = extern union {
    unexpectedEof: Loc,
};

const SourceToGraphResult = Result(Slice, SourceToGraphErr);

// TODO
// fn UnionWithCType(comptime Union: type) type {
//     var result = Union;
//     const CType = struct {
//         tag: tag_type,
//         payload: union_type,
//     };

//     const Impl = struct {
//         fn toC(in: Union) CType {
//             return .{ tag = 5, .payload = in },
//         }
//     };

//     var CType = @Type(.{
//         .@"enum" = .{
//             .tag_type = c_int,
//             .payload: @typeInfo(GraphToSourceErr).Union.fields,
//         },
//     });

//     Union.functions = Union.functions ++ .{Impl.toC};
//     return result;
// }

// FIXME: need a tag :/
const GraphToSourceErr = union (enum) {
    jsonNodesDoesntExist: void,
    jsonNodesNotAMap: void,
    jsonRootNotObject: void,
    jsonParseFailure: void,
    ioErr: void,

    pub const C = extern struct {
        tag: u8,
        payload: extern union {
            jsonNodesDoesntExist: void,
            jsonNodesNotAMap: void,
            jsonRootNotObject: void,
            jsonParseFailure: void,
            ioErr: void,
        },
    };

    fn toC(self: @This()) C {
        return switch (self) {
            inline else => |val, tag| .{
                .tag = @enumToInt(self),
                .payload = @unionInit(
                    // TODO: compileError assert that this is the field named "payload"
                    @typeInfo(C).Struct.fields[1].field_type,
                    // requires enum tags/names are the same
                    @tagName(tag),
                    val
                ),
            },
        };
    }
};

const GraphToSourceResult = Result(Slice, GraphToSourceErr.C);

// interface graph {
//   nodes: {
//     [nodeId: string]: {
//       type: string
//       inputs: string[]
//     }
//   }
// }

/// call c free on result
export fn graph_to_source(graph_json: Slice) GraphToSourceResult {
    var parser = json.Parser.init(std.heap.c_allocator, false);
    defer parser.deinit();
    const err: GraphToSourceErr = GraphToSourceErr.jsonParseFailure;
    _ = err.toC();
    var json_doc = parser.parse(graph_json.to_zig())
        catch return .{.err = (GraphToSourceErr{.jsonParseFailure={}}).toC()};
    defer json_doc.deinit();

    const nodes = switch (json_doc.root) {
        .Object => |root| switch (root.get("nodes")
            orelse return .{.err = @as(GraphToSourceErr, .jsonNodesDoesntExist).toC() }) {
            .Object => |a| a,
            else => return .{.err = @as(GraphToSourceErr, .jsonNodesNotAMap).toC()},
        },
        else => return .{.err = @as(GraphToSourceErr, .jsonRootNotObject).toC()},
    };

    for (nodes.keys()) |k| {
        std.fmt.format(std.io.getStdOut().writer(), "test {any}", .{k})
            catch return .{.err = (GraphToSourceErr{.ioErr={}}).toC()};
    }

    return .{.ok = Slice.from_zig("")};
}


/// call c free on result
export fn source_to_graph(source: Slice) SourceToGraphResult {
    _ = source;
    return .{.ok = Slice.from_zig("")};
}

test "basic add functionality" {
    try testing.expectEqualStrings(source_to_graph(""), "");
    try testing.expectEqualStrings(graph_to_source(""), "");
}
