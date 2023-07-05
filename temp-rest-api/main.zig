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


/// caller must free result
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

    return .{.ok = Slice.from_zig("")};
}

test "basic graph_to_source" {
    try testing.expectEqualStrings(
        \\(define a (range-picker 1 42 100))
        \\(+ 11 a)
        ,
        Slice.to_zig(source_to_graph(Slice.from_zig(
        \\{
        \\  "nodes": {
        \\    "node_1": {
        \\      "type": "ranged-picker",
        \\      "inputs": [{ value: 42 }],
        \\      "props": {
        \\        "min": "1",
        \\        "max": "100"
        \\      }
        \\    },
        \\    "node_2": {
        \\      "type": "add",
        \\      "inputs": [{ value: 11 }, { link: "node_1" }]
        \\    }
        \\  }
        \\}
        )).ok)
    );
}


/// call c free on result
export fn source_to_graph(source: Slice) SourceToGraphResult {
    _ = source;
    return .{.ok = Slice.from_zig("")};
}

// test "source_to_graph" {
// }
