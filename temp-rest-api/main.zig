const std = @import("std");
const FileBuffer = @import("./FileBuffer.zig");
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

const Sexp = union (enum) {
    call: struct {
        callee: *const Sexp,
        args: std.ArrayList(Sexp),
    },
    int: i64,
    float: f64,
    /// this Sexp owns the referenced memory, it must be freed
    ownedString: []const u8,
    /// this Sexp is borrowing the referenced memory, it should not be freed
    borrowedString: []const u8,
    /// always borrowed
    symbol: []const u8,
    // TODO: quote/quasiquote, etc

    const Self = @This();

    fn deinit(self: Self, alloc: std.mem.Allocator) void {
        switch (self) {
            .ownedString => |v| alloc.free(v),
            else => {},
        }
    }

    fn write(self: Self, writer: anytype) !usize {
        var total_bytes_written: usize = 0;
        switch (self) {
            .call => |v| {
                total_bytes_written += try writer.write("(");
                total_bytes_written += try v.callee.write(writer);
                if (v.args.items.len > 0)
                    total_bytes_written += try writer.write(" ");
                for (v.args.items) |arg, i| {
                    total_bytes_written += try arg.write(writer);
                    if (i != v.args.items.len - 1)
                        total_bytes_written += try writer.write(" ");
                }
                total_bytes_written += try writer.write(")");
            },
            // FIXME: the bytecounts here are ignored!
            .float => |v| try std.fmt.format(writer, "{d}", .{v}),
            .int => |v| try std.fmt.format(writer, "{d}", .{v}),
            .ownedString, .borrowedString => |v| try std.fmt.format(writer, "\"{s}\"", .{v}),
            .symbol => |v| try std.fmt.format(writer, "{s}", .{v}),
        }
        return total_bytes_written;
    }
};

test "free sexp" {
    const alloc = std.testing.allocator;
    const str = Sexp{.ownedString = try alloc.alloc(u8, 10)};
    defer str.deinit(alloc);
}

test "write sexp" {
    var root_args = std.ArrayList(Sexp).init(std.testing.allocator);
    const arg1 = try root_args.addOne();
    arg1.* = Sexp{.float = 0.5};
    defer root_args.deinit();
    var root_sexp = Sexp{.call = .{
        .callee=&Sexp{.symbol="hello"},
        .args=root_args,
    }};

    var buff: [1024]u8 = undefined;
    var fixedBufferStream = std.io.fixedBufferStream(&buff);
    var writer = fixedBufferStream.writer();

    _ = try root_sexp.write(writer);

    try testing.expectEqualStrings(
        \\(hello 0.5)
        ,
        buff[0..11] // not using result of write because it is currently wrong
    );
}

// interface graph {
//   nodes: {
//     [nodeId: string]: {
//       type: string
//       inputs: string[]
//     }
//   }
//   imports: {
//     [packageName: string]: {
//       ref: string
//       alias?: string
//     }[]
//   }
// }

/// caller must free result with {TBD}
export fn graph_to_source(graph_json: Slice) GraphToSourceResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var parser = json.Parser.init(arena_alloc, false);
    defer parser.deinit();

    var json_doc = parser.parse(graph_json.to_zig())
        catch return .{.err = @as(GraphToSourceErr, .jsonParseFailure).toC()};
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

    // TODO: create a writer that keeps track of a list of pages, and always buffered writes to a fresh page,
    // until we're done, then we can iterate over the pages, allocate the required linear memory, and combine
    // the chunks.
    //const chunks_writer = std.io.bufferedWriter(std.io.Writer)

    return .{.ok = Slice.from_zig("")};
}

test "big graph_to_source" {
    const alloc = std.testing.allocator;
    const source = try FileBuffer.fromDirAndPath(alloc, std.fs.cwd(), "./tests/large1/source.scm");
    defer source.free(alloc);
    const graph_json = try FileBuffer.fromDirAndPath(alloc, std.fs.cwd(), "./tests/large1/graph.json");
    defer graph_json.free(alloc);
    // NOTE: it is extremely vague how we're going to isomorphically convert
    // variable definitions... can variables be declared at any point in the node graph?
    // will variables in the source have to have "global" names?
    // Does synchronizing graph changes into the source affect those?
    try testing.expectEqualStrings(
        source.buffer,
        Slice.to_zig(source_to_graph(Slice.from_zig(graph_json.buffer)).ok)
    );
}


/// call c free on result
export fn source_to_graph(source: Slice) SourceToGraphResult {
    _ = source;
    return .{.ok = Slice.from_zig("")};
}

// test "source_to_graph" {
// }
