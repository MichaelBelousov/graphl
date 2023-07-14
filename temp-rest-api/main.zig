const std = @import("std");
const builtin = @import("builtin");
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

pub fn Result(comptime R: type) type {
    return extern struct {
        /// not initialized if err is not 0/null
        result: R,
        err: ?[*:0]const u8,
        /// 0 if result is valid
        errCode: u8,

        fn ok(r: R) @This() {
            return @This() {
                .result = r,
                .err = null,
                .errCode = 0,
            };
        }

        fn err(e: [*:0]const u8) @This() {
            return @This() {
                .result = undefined,
                .err = e,
                .errCode = 1, // FIXME: not used
            };
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

const SourceToGraphResult = Result(Slice);

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

    /// caller must free the result
    pub fn explain(self: @This(), al: std.mem.Allocator) ![*:0]const u8 {
        return switch (self) {
            inline else => |v| try std.fmt.allocPrintZ(al, "Error: '{s}', {}", .{@tagName(self), v}),
        };
    }
};

const GraphToSourceResult = Result(Slice);

/// TODO: infer the error type from the result
fn err_explain(comptime R: type, e: GraphToSourceErr) R {
    return R.err(GraphToSourceErr.explain(e, global_alloc.allocator())
        catch |sub_err| std.debug.panic("error '{}' while explaining an error", .{sub_err}));
}

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


// FIXME use wasm known memory limits or something
var result_buffer: [std.mem.page_size * 512]u8 = undefined;
var global_alloc = std.heap.FixedBufferAllocator.init(&result_buffer);

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
        catch return err_explain(GraphToSourceResult, .jsonParseFailure);
    defer json_doc.deinit();

    const json_imports = switch (json_doc.root) {
        .Object => |root| switch (root.get("imports")
            orelse return err_explain(GraphToSourceResult, .jsonNoImports)) {
            .Object => |a| a,
            else => return err_explain(GraphToSourceResult, .jsonImportsNotAMap),
        },
        else => return err_explain(GraphToSourceResult, .jsonRootNotObject),
    };

    // FIXME: shouldn't we know node and import counts from the graph after parsing? Can
    // potentially allocate one big arraylist
    var import_exprs = std.SegmentedList(Sexp, 16){};

    {
        var json_imports_iter = json_imports.iterator();
        while (json_imports_iter.next()) |json_import_entry| {
            const json_import_name = json_import_entry.key_ptr.*;
            const json_import_bindings = json_import_entry.value_ptr.*;

            const new_import = import_exprs.addOne(arena_alloc)
                catch return err_explain(GraphToSourceResult, .OutOfMemory);

            // TODO: it is tempting to create a comptime function that constructs sexp from zig tuples
            new_import.* = Sexp{.call = .{
                .callee = &syms.import,
                .args = std.ArrayList(Sexp).init(arena_alloc),
            }};
            (new_import.*.call.args.addOne()
                catch return err_explain(GraphToSourceResult, .OutOfMemory)
            ).* = Sexp{.symbol = json_import_name};

            const first_binding_empty = "";
            var first_binding = Sexp{.symbol = first_binding_empty};

            const imported_bindings = new_import.*.call.args.addOne()
                catch return err_explain(GraphToSourceResult, .OutOfMemory);
            imported_bindings.* = Sexp{.call = .{
                .callee = &first_binding,
                .args = std.ArrayList(Sexp).init(arena_alloc),
            }};

            if (json_import_bindings != .Array)
                return err_explain(GraphToSourceResult, .jsonImportedBindingsNotArray);

            if (json_import_bindings.Array.items.len == 0)
                return err_explain(GraphToSourceResult, .jsonImportedBindingsEmpty);

            for (json_import_bindings.Array.items) |json_imported_binding| {
                if (json_imported_binding != .Object)
                    return err_explain(GraphToSourceResult, .jsonImportedBindingNotObject);

                const ref = json_imported_binding.Object.get("ref")
                    orelse return err_explain(GraphToSourceResult, .jsonImportedBindingNoRef);
                if (ref != .String)
                    return err_explain(GraphToSourceResult, .jsonImportedBindingRefNotString);

                const maybe_alias = json_imported_binding.Object.get("alias");


                var added =
                    if (std.mem.eql(u8, imported_bindings.*.call.callee.symbol, first_binding_empty))
                        &first_binding
                    else
                        imported_bindings.*.call.args.addOne()
                            catch return err_explain(GraphToSourceResult, .OutOfMemory);

                if (maybe_alias) |alias| {
                    if (alias != .String)
                        return err_explain(GraphToSourceResult, .jsonImportedBindingAliasNotString);
                    added.* = Sexp{.call = .{
                        .callee = &syms.as,
                        .args = std.ArrayList(Sexp).init(arena_alloc),
                    }};
                    (added.*.call.args.addOne()
                        catch return err_explain(GraphToSourceResult, .OutOfMemory)
                    ).* = Sexp{.symbol = ref.String};
                    (added.*.call.args.addOne()
                        catch return err_explain(GraphToSourceResult, .OutOfMemory)
                    ).* = Sexp{.symbol = alias.String};
                } else {
                    added.* = Sexp{.symbol = ref.String};
                }
            }

            std.debug.assert(!std.mem.eql(u8, imported_bindings.*.call.callee.symbol, first_binding_empty));
        }
    }

    var node_exprs = std.SegmentedList(Sexp, 64){};

    const json_nodes = switch (json_doc.root) {
        .Object => |root| switch (root.get("nodes")
            orelse return err_explain(GraphToSourceResult, .jsonNoNodes)) {
            .Object => |a| a,
            else => return err_explain(GraphToSourceResult, .jsonNodesNotAMap),
        },
        else => return err_explain(GraphToSourceResult, .jsonRootNotObject),
    };

    {
        var json_nodes_iter = json_nodes.iterator();
        while (json_nodes_iter.next()) |json_node_entry| {
            const json_node_name = json_node_entry.key_ptr.*;
            //const json_node_data = json_node_entry.value_ptr.*;

            const new_node = node_exprs.addOne(arena_alloc)
                catch return err_explain(GraphToSourceResult, .OutOfMemory);

            // TODO: it is tempting to create a comptime function that constructs sexp from zig tuples
            new_node.* = Sexp{.call = .{
                .callee = &syms.import,
                .args = std.ArrayList(Sexp).init(arena_alloc),
            }};
            (new_node.*.call.args.addOne()
                catch return err_explain(GraphToSourceResult, .OutOfMemory)
            ).* = Sexp{.symbol = json_node_name};
        }
    }

    var page_writer = PageWriter.init(std.heap.page_allocator)
        catch return err_explain(GraphToSourceResult, .OutOfMemory);
    defer page_writer.deinit();

    {
        var import_iter = import_exprs.constIterator(0);
        while (import_iter.next()) |import| {
            _ = import.write(page_writer.writer())
                catch return err_explain(GraphToSourceResult, .ioErr);
            _ = page_writer.writer().write("\n")
                catch return err_explain(GraphToSourceResult, .ioErr);
        }
    }
    _ = page_writer.writer().write("\n")
        catch return err_explain(GraphToSourceResult, .ioErr);

    return GraphToSourceResult.ok(Slice.from_zig(
        // FIXME: make sure we can free this
        page_writer.concat(global_alloc.allocator())
            catch return err_explain(GraphToSourceResult, .OutOfMemory)
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

test "source_to_graph" {
}


/// call c free on result
export fn source_to_graph(source: Slice) SourceToGraphResult {
    _ = source;
    return SourceToGraphResult.ok(Slice.from_zig(""));
}

fn alloc_string(byte_count: usize) callconv(.C) [*:0]u8 {
    return (
        global_alloc.allocator().allocSentinel(u8, byte_count, 0)
        catch |e| return std.debug.panic("alloc error: {}", .{e})
    ).ptr;
}

fn free_string(str: [*:0]u8) callconv(.C) void {
    return global_alloc.allocator().free(str[0..std.mem.len(str)]);
}

comptime {
    if (builtin.target.cpu.arch == .wasm32) {
        @export(alloc_string, .{ .name = "alloc_string", .linkage = .Strong });
        @export(free_string, .{ .name = "free_string", .linkage = .Strong });
    }
}

// TODO: only export in wasi
pub fn main() void {}

