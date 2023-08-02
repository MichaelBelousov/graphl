const std = @import("std");
const builtin = @import("builtin");
const FileBuffer = @import("./FileBuffer.zig");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const io = std.io;
const testing = std.testing;
const json = std.json;

const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;
const ide_json_gen = @import("./ide_json_gen.zig");

// TODO: give better name... C slice?
pub const Slice = extern struct {
    ptr: [*]const u8,
    len: usize,

    fn fromZig(slice: []const u8) @This() {
        return @This(){ .ptr = slice.ptr, .len = slice.len };
    }

    fn toZig(self: @This()) []const u8 {
        return self.ptr[0..self.len];
    }
};

const Result = @import("./result.zig").Result;

const Loc = @import("./loc.zig").Loc;

const SourceToGraphErr = extern union {
    unexpectedEof: Loc,
};

const SourceToGraphResult = Result(Slice);

const GraphToSourceErr = union(enum) {
    ioErr: void,
    OutOfMemory: void,

    /// caller must free the result
    pub fn explain(self: @This(), al: std.mem.Allocator) ![*:0]const u8 {
        return switch (self) {
            inline else => |v| try std.fmt.allocPrintZ(al, "Error: '{s}', {}", .{ @tagName(self), v }),
        };
    }
};

const GraphToSourceResult = Result([]const u8);
/// TODO: infer the error type from the result
fn err_explain(comptime R: type, e: GraphToSourceErr) R {
    return R.err(GraphToSourceErr.explain(e, global_alloc) catch |sub_err| std.debug.panic("error '{}' while explaining an error", .{sub_err}));
}

fn recurseRootNodeToSexp(node: Node, alloc: std.mem.Allocator, in_handle_src_node_map: std.AutoHashMap(i64, *const Node)) Result(Sexp) {
    var result = Sexp{ .list = std.ArrayList(Sexp).init(alloc) };

    // TODO: it is tempting to create a comptime function that constructs sexp from zig tuples
    (result.list.addOne() catch return err_explain(Result(Sexp), .OutOfMemory)).* = Sexp{ .symbol = node.type };

    // FIXME: handle literals...
    for (node.inputs) |input| {
        //if (input != .pin)
            //@panic("not yet supported!");

        const source_node = in_handle_src_node_map.get(input)
            orelse return Result(Sexp).fmt_err(global_alloc, "{} (handle {})", .{ error.undefinedInputHandle, input });

        const next = recurseRootNodeToSexp(source_node.*, alloc, in_handle_src_node_map);
        if (next.is_err())
            return next;

        (result.list.addOne()
            catch |e| return Result(Sexp).fmt_err(global_alloc, "{}", .{e})
        ).* = next.result;
    }

    return Result(Sexp).ok(result);
}

const Node = struct {
    type: []const u8,
    inputs: []const i64, //union (enum) { pin: i64 },
    outputs: []const i64,
};

const Import = struct {
    ref: []const u8,
    alias: ?[]const u8,
};

const empty_imports = json.ArrayHashMap([]const Import){};

const GraphDoc = struct {
    nodes: json.ArrayHashMap(Node),
    imports: json.ArrayHashMap([]const Import) = empty_imports,
};

/// caller must free result with {TBD}
fn graphToSource(graph_json: []const u8) GraphToSourceResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var json_diagnostics = json.Diagnostics{};
    var graph_json_reader = json.Scanner.initCompleteInput(arena_alloc, graph_json);
    graph_json_reader.enableDiagnostics(&json_diagnostics);
    const graph = json.parseFromTokenSourceLeaky(GraphDoc, arena_alloc, &graph_json_reader, .{
        .ignore_unknown_fields = true,
    }) catch |e| return GraphToSourceResult.fmt_err(global_alloc, "{}: {}", .{e, json_diagnostics});

    var page_writer = PageWriter.init(std.heap.page_allocator)
        catch |e| return GraphToSourceResult.fmt_err(global_alloc, "{}", .{e});
    defer page_writer.deinit();

    var import_exprs = std.ArrayList(Sexp).init(arena_alloc);
    defer import_exprs.deinit();
    import_exprs.ensureTotalCapacityPrecise(graph.imports.map.count())
        catch |e| return GraphToSourceResult.fmt_err(global_alloc, "{}", .{e});

    // TODO: refactor blocks into functions
    {
        {
            var imports_iter = graph.imports.map.iterator();
            while (imports_iter.next()) |json_import_entry| {
                const json_import_name = json_import_entry.key_ptr.*;
                const json_import_bindings = json_import_entry.value_ptr.*;

                const new_import = import_exprs.addOne() catch return err_explain(GraphToSourceResult, .OutOfMemory);

                // TODO: it is tempting to create a comptime function that constructs sexp from zig tuples
                new_import.* = Sexp{
                    .list = std.ArrayList(Sexp).init(arena_alloc),
                };
                (new_import.*.list.addOne() catch return err_explain(GraphToSourceResult, .OutOfMemory)).* = syms.import;
                (new_import.*.list.addOne() catch return err_explain(GraphToSourceResult, .OutOfMemory)).* = Sexp{ .symbol = json_import_name };

                const imported_bindings = new_import.*.list.addOne() catch return err_explain(GraphToSourceResult, .OutOfMemory);
                imported_bindings.* = Sexp{ .list = std.ArrayList(Sexp).init(arena_alloc) };

                for (json_import_bindings) |json_imported_binding| {
                    const ref = json_imported_binding.ref;
                    var added = imported_bindings.*.list.addOne() catch return err_explain(GraphToSourceResult, .OutOfMemory);

                    if (json_imported_binding.alias) |alias| {
                        (added.*.list.addOne() catch return err_explain(GraphToSourceResult, .OutOfMemory)).* = syms.as;
                        (added.*.list.addOne() catch return err_explain(GraphToSourceResult, .OutOfMemory)).* = Sexp{ .symbol = ref };
                        (added.*.list.addOne() catch return err_explain(GraphToSourceResult, .OutOfMemory)).* = Sexp{ .symbol = alias };
                    } else {
                        added.* = Sexp{ .symbol = ref };
                    }
                }
            }
        }

        for (import_exprs.items) |import| {
            _ = import.write(page_writer.writer()) catch return err_explain(GraphToSourceResult, .ioErr);
            _ = page_writer.writer().write("\n") catch return err_explain(GraphToSourceResult, .ioErr);
        }
    }

    // FIXME: break block out into function
    {
        var handle_src_node_map = std.AutoHashMap(i64, *const Node).init(arena_alloc);
        handle_src_node_map.deinit();

        {
            var nodes_iter = graph.nodes.map.iterator();
            while (nodes_iter.next()) |node_entry| {
                const node = node_entry.value_ptr.*;

                for (node.outputs) |json_output| {
                    // FIXME:
                    @setRuntimeSafety(false); // FIXME: weird pointer alignment error
                    handle_src_node_map.put(json_output, node_entry.value_ptr)
                        catch |e| return GraphToSourceResult.fmt_err(global_alloc, "{}", .{e});
                }
            }
        }

        {
            var nodes_iter = graph.nodes.map.iterator();
            while (nodes_iter.next()) |node_entry| {
                const node = node_entry.value_ptr.*;

                const is_root = node.outputs.len == 0;
                if (!is_root) continue;

                const maybe_sexp = recurseRootNodeToSexp(node, arena_alloc, handle_src_node_map);
                if (maybe_sexp.is_err())
                    return GraphToSourceResult.fmt_err(global_alloc, "{s}", .{maybe_sexp.err.?});

                _ = maybe_sexp.result.write(page_writer.writer()) catch return err_explain(GraphToSourceResult, .ioErr);
                _ = page_writer.writer().write("\n") catch return err_explain(GraphToSourceResult, .ioErr);
            }
        }
    }

    _ = page_writer.writer().write("\n") catch return err_explain(GraphToSourceResult, .ioErr);

    return GraphToSourceResult.ok(
    // FIXME: provide API to free this
    page_writer.concat(global_alloc) catch return err_explain(GraphToSourceResult, .OutOfMemory));
}

test "big graph_to_source" {
    const alloc = std.testing.allocator;
    const source = try FileBuffer.fromDirAndPath(alloc, std.fs.cwd(), "./tests/ue1/source.scm");
    defer source.free(alloc);
    const graph_json = try FileBuffer.fromDirAndPath(alloc, std.fs.cwd(), "./tests/ue1/prototype_graph.json");
    defer graph_json.free(alloc);

    // NOTE: it is extremely vague how we're going to isomorphically convert
    // variable definitions... can variables be declared at any point in the node graph?
    // will scoping be function-level?
    // Does synchronizing graph changes into the source affect those?

    const result = graph_to_source(Slice.fromZig(graph_json.buffer));
    if (result.is_err()) {
        std.debug.print("\n{?s}\n", .{result.err});
        return error.FailTest;
    }
    try testing.expectEqualStrings(source.buffer, Slice.toZig(result.result));
}

export fn graph_to_source(graph_json: Slice) Result(Slice) {
    const zig_result = graphToSource(graph_json.toZig());
    return Result(Slice){
        .result = Slice.fromZig(zig_result.result),
        .err = zig_result.err,
        .errCode = zig_result.errCode,
    };
}

test "source_to_graph" {}

// FIXME use wasm known memory limits or something
var result_buffer: [std.mem.page_size * 512]u8 = undefined;
var global_allocator_inst = std.heap.FixedBufferAllocator.init(&result_buffer);
var global_alloc = global_allocator_inst.allocator();

/// call c free on result
export fn source_to_graph(source: Slice) SourceToGraphResult {
    _ = source;
    return SourceToGraphResult.ok(Slice.fromZig(""));
}

fn alloc_string(byte_count: usize) callconv(.C) [*:0]u8 {
    return (global_alloc.allocSentinel(u8, byte_count, 0) catch |e| return std.debug.panic("alloc error: {}", .{e})).ptr;
}

fn free_string(str: [*:0]u8) callconv(.C) void {
    return global_alloc.free(str[0..std.mem.len(str)]);
}

export fn readSrc(src: [*:0]const u8, in_status: ?*c_int) [*:0]const u8 {
    var ignored_status: c_int = 0;
    const out_status = in_status orelse &ignored_status;

    var page_writer = PageWriter.init(std.heap.page_allocator) catch {
        out_status.* = 1;
        return "Error: allocation err";
    };
    defer page_writer.deinit();

    ide_json_gen.readSrc(global_alloc, src[0..std.mem.len(src)], page_writer.writer()) catch {
        out_status.* = 1;
        return "Error: parse error";
    };

    page_writer.writer().writeByte(0) catch {
        out_status.* = 1;
        return "Error: write error";
    };

    // FIXME: leak
    return @as([*:0]const u8, @ptrCast((page_writer.concat(global_alloc) catch {
        out_status.* = 1;
        return "Error: alloc concat error";
    }).ptr));
}

// TODO: only export in wasi
pub fn main() void {}

comptime {
    if (builtin.target.cpu.arch == .wasm32) {
        @export(alloc_string, .{ .name = "alloc_string", .linkage = .Strong });
        @export(free_string, .{ .name = "free_string", .linkage = .Strong });
    }
}
