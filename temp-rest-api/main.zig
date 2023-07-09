const std = @import("std");
const FileBuffer = @import("./FileBuffer.zig");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const io = std.io;
const testing = std.testing;
const json = std.json;

// TODO: give better name... C slice?
pub const Slice = extern struct {
    ptr: [*]const u8,
    len: usize,

    fn from_zig(slice: []const u8) @This() {
        return @This(){ .ptr = slice.ptr, .len = slice.len };
    }

    fn to_zig(self: @This()) []const u8 {
        return self.ptr[0..self.len];
    }
};

pub fn Result(comptime R: type, comptime E: type) type {
    // TODO: move c-like tagging to utility
    return extern struct {
        val: extern union {
            ok: R,
            err: E,
        },
        tag: enum (u8) {
            ok,
            err,
        },

        fn ok(r: R) @This() {
            return @This(){.val = .{.ok = r}, .tag = .ok};
        }

        fn err(e: E) @This() {
            return @This(){.val = .{.err = e},  .tag = .err};
        }
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
    jsonImportedBindingAliasNotString: void,
    jsonImportedBindingNoRef: void,
    jsonImportedBindingNotObject: void,
    jsonImportedBindingRefNotString: void,
    jsonImportedBindingsNotArray: void,
    jsonImportedBindingsEmpty: void,
    jsonImportsNotAMap: void,
    jsonNodesNotAMap: void,
    jsonNoImports: void,
    jsonNoNodes: void,
    jsonParseFailure: void,
    jsonRootNotObject: void,
    ioErr: void,
    OutOfMemory: void,

    pub const C = extern struct {
        tag: u8,
        payload: extern union {
            jsonImportedBindingAliasNotString: void,
            jsonImportedBindingNoRef: void,
            jsonImportedBindingNotObject: void,
            jsonImportedBindingRefNotString: void,
            jsonImportedBindingsNotArray: void,
            jsonImportedBindingsEmpty: void,
            jsonImportsNotAMap: void,
            jsonNodesNotAMap: void,
            jsonNoImports: void,
            jsonNoNodes: void,
            jsonParseFailure: void,
            jsonRootNotObject: void,
            ioErr: void,
            OutOfMemory: void,
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
            .call => |v| v.args.deinit(),
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

const syms = struct {
    const import = Sexp{.symbol = "import"};
    const define = Sexp{.symbol = "define"};
    const as = Sexp{.symbol = "as"};
    const VOID = Sexp{.symbol = "__VOID__"};
};

// TODO: add a json schema to document this instead... and petition zig for support of JSON maps
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
        catch return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonParseFailure).toC());
    defer json_doc.deinit();

    const json_imports = switch (json_doc.root) {
        .Object => |root| switch (root.get("imports")
            orelse return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonNoImports).toC())) {
            .Object => |a| a,
            else => return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonImportsNotAMap).toC()),
        },
        else => return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonRootNotObject).toC()),
    };

    // TODO: is it worth using a segmented list if an array list will do? Will graphs really
    // ever be that large?
    var import_exprs = std.SegmentedList(Sexp, 16){};

    {
        var json_imports_iter = json_imports.iterator();
        while (json_imports_iter.next()) |json_import_entry| {
            const json_import_name = json_import_entry.key_ptr.*;
            const json_import_bindings = json_import_entry.value_ptr.*;

            const new_import = import_exprs.addOne(arena_alloc)
                catch return GraphToSourceResult.err(@as(GraphToSourceErr, .OutOfMemory).toC());

            // TODO: it is tempting to create a comptime function that constructs sexp from zig tuples
            new_import.* = Sexp{.call = .{
                .callee = &syms.import,
                .args = std.ArrayList(Sexp).init(arena_alloc),
            }};
            (new_import.*.call.args.addOne()
                catch return GraphToSourceResult.err(@as(GraphToSourceErr, .OutOfMemory).toC())
            ).* = Sexp{.symbol = json_import_name};

            const first_binding_empty = "";
            var first_binding = Sexp{.symbol = first_binding_empty};

            const imported_bindings = new_import.*.call.args.addOne()
                catch return GraphToSourceResult.err(@as(GraphToSourceErr, .OutOfMemory).toC());
            imported_bindings.* = Sexp{.call = .{
                .callee = &first_binding,
                .args = std.ArrayList(Sexp).init(arena_alloc),
            }};

            if (json_import_bindings != .Array)
                return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonImportedBindingsNotArray).toC());

            if (json_import_bindings.Array.items.len == 0)
                return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonImportedBindingsEmpty).toC());

            for (json_import_bindings.Array.items) |json_imported_binding| {
                if (json_imported_binding != .Object)
                    return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonImportedBindingNotObject).toC());

                const ref = json_imported_binding.Object.get("ref")
                    orelse return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonImportedBindingNoRef).toC());
                if (ref != .String)
                    return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonImportedBindingRefNotString).toC());

                const maybe_alias = json_imported_binding.Object.get("alias");


                var added =
                    if (std.mem.eql(u8, imported_bindings.*.call.callee.symbol, first_binding_empty))
                        &first_binding
                    else
                        imported_bindings.*.call.args.addOne()
                            catch return GraphToSourceResult.err(@as(GraphToSourceErr, .OutOfMemory).toC());

                if (maybe_alias) |alias| {
                    if (alias != .String)
                        return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonImportedBindingAliasNotString).toC());
                    added.* = Sexp{.call = .{
                        .callee = &syms.as,
                        .args = std.ArrayList(Sexp).init(arena_alloc),
                    }};
                    (added.*.call.args.addOne()
                        catch return GraphToSourceResult.err(@as(GraphToSourceErr, .OutOfMemory).toC())
                    ).* = Sexp{.symbol = ref.String};
                    (added.*.call.args.addOne()
                        catch return GraphToSourceResult.err(@as(GraphToSourceErr, .OutOfMemory).toC())
                    ).* = Sexp{.symbol = alias.String};
                } else {
                    added.* = Sexp{.symbol = ref.String};
                }
            }

            std.debug.assert(!std.mem.eql(u8, imported_bindings.*.call.callee.symbol, first_binding_empty));
        }
    }

    const nodes = switch (json_doc.root) {
        .Object => |root| switch (root.get("nodes")
            orelse return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonNoNodes).toC())) {
            .Object => |a| a,
            else => return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonNodesNotAMap).toC()),
        },
        else => return GraphToSourceResult.err(@as(GraphToSourceErr, .jsonRootNotObject).toC()),
    };

    for (nodes.keys()) |k| {
        std.fmt.format(std.io.getStdOut().writer(), "test {any}", .{k})
            catch return GraphToSourceResult.err((GraphToSourceErr{.ioErr={}}).toC());
    }

    var page_writer = PageWriter.init(std.heap.page_allocator)
        catch return GraphToSourceResult.err((GraphToSourceErr{.OutOfMemory={}}).toC());
    defer page_writer.deinit();

    {
        var import_iter = import_exprs.constIterator(0);
        while (import_iter.next()) |import| {
            _ = import.write(page_writer.writer())
                catch return GraphToSourceResult.err((GraphToSourceErr{.ioErr={}}).toC());
            _ = page_writer.writer().write("\n")
                catch return GraphToSourceResult.err((GraphToSourceErr{.ioErr={}}).toC());
        }
    }
    _ = page_writer.writer().write("\n")
        catch return GraphToSourceResult.err((GraphToSourceErr{.ioErr={}}).toC());

    return GraphToSourceResult.ok(Slice.from_zig(
        // FIXME: make sure we can free this
        page_writer.concat(std.heap.c_allocator)
            catch return GraphToSourceResult.err(@as(GraphToSourceErr, .OutOfMemory).toC())
    ));
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

    const result = graph_to_source(Slice.from_zig(graph_json.buffer));
    try testing.expect(result.tag == .ok);
    try testing.expectEqualStrings(
        source.buffer,
        Slice.to_zig(result.val.ok)
    );
}


/// call c free on result
export fn source_to_graph(source: Slice) SourceToGraphResult {
    _ = source;
    return SourceToGraphResult.ok(Slice.from_zig(""));
}

// test "source_to_graph" {
// }
