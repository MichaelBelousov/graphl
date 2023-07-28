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


fn ResultDecls(comptime R: type, comptime Self: type) type {
    return struct {
        fn is_ok(self: Self) bool {
            return self.err == null;
        }

        fn is_err(self: Self) bool {
            return !self.is_ok();
        }

        fn ok(r: R) Self {
            return Self {
                .result = r,
                .err = null,
                .errCode = 0,
            };
        }

        fn err(e: [*:0]const u8) Self {
            return Self {
                .result = undefined,
                .err = e,
                // FIXME: not used
                .errCode = 1,
            };
        }

        fn fmt_err(comptime fmt_str: []const u8, fmt_args: anytype) Self {
            return Self{
                .result = undefined,
                .err = std.fmt.allocPrintZ(global_alloc.allocator(), "Error: " ++ fmt_str, fmt_args)
                    catch |sub_err| std.debug.panic("error '{}' while explaining an error", .{sub_err}),
                .errCode = fmtStringId(fmt_str),
            };
        }
    };
}

pub fn Result(comptime R: type) type {
    // FIXME: gross
    if (@typeInfo(R).Struct.layout == .Extern) {
        return struct {
            /// not initialized if err is not 0/null
            result: R,
            err: ?[*:0]const u8,
            // TODO: try to compress to u16 if possible
            /// 0 if result is valid
            errCode: usize,

            //pub usingnamespace ResultDecls(R, @This());
            const Self = @This();

            fn is_ok(self: Self) bool {
                return self.err == null;
            }

            fn is_err(self: Self) bool {
                return !self.is_ok();
            }

            fn ok(r: R) Self {
                return Self {
                    .result = r,
                    .err = null,
                    .errCode = 0,
                };
            }

            fn err(e: [*:0]const u8) Self {
                return Self {
                    .result = undefined,
                    .err = e,
                    // FIXME: not used
                    .errCode = 1,
                };
            }

            fn fmt_err(comptime fmt_str: []const u8, fmt_args: anytype) Self {
                return Self{
                    .result = undefined,
                    .err = std.fmt.allocPrintZ(global_alloc.allocator(), "Error: " ++ fmt_str, fmt_args)
                        catch |sub_err| std.debug.panic("error '{}' while explaining an error", .{sub_err}),
                    .errCode = fmtStringId(fmt_str),
                };
            }
        };
    } else  {
        return extern struct {
            /// not initialized if err is not 0/null
            result: R,
            err: ?[*:0]const u8,
            // TODO: try to compress to u16 if possible
            /// 0 if result is valid
            errCode: usize,

            //pub usingnamespace ResultDecls(R, @This());
            const Self = @This();

            fn is_ok(self: Self) bool {
                return self.err == null;
            }

            fn is_err(self: Self) bool {
                return !self.is_ok();
            }

            fn ok(r: R) Self {
                return Self {
                    .result = r,
                    .err = null,
                    .errCode = 0,
                };
            }

            fn err(e: [*:0]const u8) Self {
                return Self {
                    .result = undefined,
                    .err = e,
                    // FIXME: not used
                    .errCode = 1,
                };
            }

            fn fmt_err(comptime fmt_str: []const u8, fmt_args: anytype) Self {
                return Self{
                    .result = undefined,
                    .err = std.fmt.allocPrintZ(global_alloc.allocator(), "Error: " ++ fmt_str, fmt_args)
                        catch |sub_err| std.debug.panic("error '{}' while explaining an error", .{sub_err}),
                    .errCode = fmtStringId(fmt_str),
                };
            }
        };
    }
}

// FIXME: how do I not copy this?
pub fn CResult(comptime R: type) type {
    return extern struct {
        /// not initialized if err is not 0/null
        result: R,
        err: ?[*:0]const u8,
        // TODO: try to compress to u16 if possible
        /// 0 if result is valid
        errCode: usize,

        pub usingnamespace Result(R);

        // FIXME: why is this necessary?
        // fn toZig(self: @This()) Result(R) {
        //     return Result(R){
        //         .result = self.result,
        //         .err = self.err,
        //         .errCode = self.errCode,
        //     };
        // }
    };
}

const Loc = @import("./loc.zig").Loc;

const SourceToGraphErr = extern union {
    unexpectedEof: Loc,
};

const SourceToGraphResult = CResult(Slice);

const GraphToSourceErr = union (enum) {
    ioErr: void,
    jsonImportedBindingAliasNotString: void,
    jsonImportedBindingNoRef: void,
    jsonImportedBindingNotObject: void,
    jsonImportedBindingRefNotString: void,
    jsonImportedBindingsEmpty: void,
    jsonImportedBindingsNotArray: void,
    jsonImportsNotAMap: void,
    jsonNodeInputsNotArray: void,
    jsonNodeNotObject: void,
    jsonNodeOutputNotInteger: void,
    jsonNodeOutputsNotArray: void,
    jsonNodesNotAMap: void,
    jsonNoNodes: void,
    jsonParseFailure: void,
    jsonRootNotObject: void,
    OutOfMemory: void,

    /// caller must free the result
    pub fn explain(self: @This(), al: std.mem.Allocator) ![*:0]const u8 {
        return switch (self) {
            inline else => |v| try std.fmt.allocPrintZ(al, "Error: '{s}', {}", .{@tagName(self), v}),
        };
    }
};

const GraphToSourceResult = Result(Slice);
// TODO: usingnamespace to add GraphToSourceErr directly
// const GraphToSourceResult = extern struct {
//     usingnamespace Result(Slice);
// };


/// TODO: infer the error type from the result
fn err_explain(comptime R: type, e: GraphToSourceErr) R {
    return R.err(GraphToSourceErr.explain(e, global_alloc.allocator())
        catch |sub_err| std.debug.panic("error '{}' while explaining an error", .{sub_err}));
}

// TODO: use this for a compressed logging library
fn fmtStringId(comptime fmt_str: []const u8) usize {
    return @ptrToInt(fmt_str.ptr);
}

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

const empty_object = json.Value{.Object = std.StringArrayHashMap(json.Value).init(std.testing.failing_allocator)};
const empty_array = json.Value{.Array = std.ArrayList(json.Value).init(std.testing.failing_allocator)};

/// caller must free result with {TBD}
fn graphToSource(graph_json: []const u8) Result([]const u8) {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var parser = json.Parser.init(arena_alloc, false);
    defer parser.deinit();

    var json_doc = parser.parse(graph_json)
        catch return GraphToSourceResult.fmt_err("{}", .{@as(GraphToSourceErr, .jsonParseFailure)}).toC();
    defer json_doc.deinit();

    var page_writer = PageWriter.init(std.heap.page_allocator)
        catch return GraphToSourceResult.fmt_err("{}", .{@as(GraphToSourceErr, .OutOfMemory)}).toC();
    defer page_writer.deinit();

    const json_imports = switch (json_doc.root) {
        .Object => |root| switch (root.get("imports") orelse empty_object) {
            .Object => |a| a,
            else => return GraphToSourceResult.fmt_err("{}", .{@as(GraphToSourceErr, .jsonImportsNotAMap)}).toC(),
        },
        else => return GraphToSourceResult.fmt_err("{}", .{@as(GraphToSourceErr, .jsonRootNotObject)}).toC(),
    };

    var import_exprs = std.ArrayList(Sexp).init(arena_alloc);
    defer import_exprs.deinit();
    import_exprs.ensureTotalCapacityPrecise(json_imports.count())
        catch return GraphToSourceResult.fmt_err("{}", .{.OutOfMemory}).toC();

    // TODO: refactor blocks into functions
    {
        {
            var json_imports_iter = json_imports.iterator();
            while (json_imports_iter.next()) |json_import_entry| {
                const json_import_name = json_import_entry.key_ptr.*;
                const json_import_bindings = json_import_entry.value_ptr.*;

                const new_import = import_exprs.addOne()
                    catch return err_explain(GraphToSourceResult, .OutOfMemory);

                // TODO: it is tempting to create a comptime function that constructs sexp from zig tuples
                new_import.* = Sexp{.list = std.ArrayList(Sexp).init(arena_alloc),};
                (new_import.*.list.addOne()
                    catch return err_explain(GraphToSourceResult, .OutOfMemory)
                ).* = syms.import;
                (new_import.*.list.addOne()
                    catch return err_explain(GraphToSourceResult, .OutOfMemory)
                ).* = Sexp{.symbol = json_import_name};

                const imported_bindings = new_import.*.list.addOne()
                    catch return err_explain(GraphToSourceResult, .OutOfMemory);
                imported_bindings.* = Sexp{.list = std.ArrayList(Sexp).init(arena_alloc) };

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


                    var added = imported_bindings.*.list.addOne()
                        catch return err_explain(GraphToSourceResult, .OutOfMemory);

                    if (maybe_alias) |alias| {
                        if (alias != .String)
                            return err_explain(GraphToSourceResult, .jsonImportedBindingAliasNotString);
                        (added.*.list.addOne()
                            catch return err_explain(GraphToSourceResult, .OutOfMemory)
                        ).* = syms.as;
                        (added.*.list.addOne()
                            catch return err_explain(GraphToSourceResult, .OutOfMemory)
                        ).* = Sexp{.symbol = ref.String};
                        (added.*.list.addOne()
                            catch return err_explain(GraphToSourceResult, .OutOfMemory)
                        ).* = Sexp{.symbol = alias.String};
                    } else {
                        added.* = Sexp{.symbol = ref.String};
                    }
                }
            }
        }

        for (import_exprs.items) |import| {
            _ = import.write(page_writer.writer())
                catch return err_explain(GraphToSourceResult, .ioErr);
            _ = page_writer.writer().write("\n")
                catch return err_explain(GraphToSourceResult, .ioErr);
        }
    }

    // FIXME: break block out into function
    {
        const json_nodes = switch (json_doc.root) {
            .Object => |root| switch (root.get("nodes")
                orelse return err_explain(GraphToSourceResult, .jsonNoNodes)) {
                .Object => |a| a,
                else => return err_explain(GraphToSourceResult, .jsonNodesNotAMap),
            },
            else => return err_explain(GraphToSourceResult, .jsonRootNotObject),
        };

        var node_exprs = std.ArrayList(Sexp).init(arena_alloc);
        defer node_exprs.deinit();
        node_exprs.ensureTotalCapacityPrecise(json_nodes.count())
            catch return err_explain(GraphToSourceResult, .OutOfMemory);

        var handle_src_node_map = std.AutoHashMap(i64, *const json.ObjectMap).init(arena_alloc);
        handle_src_node_map.deinit();

        var json_nodes_iter = json_nodes.iterator();
        while (json_nodes_iter.next()) |json_node_entry| {
            const json_node = switch (json_node_entry.value_ptr.*) {
                .Object => |v| v,
                else => return err_explain(GraphToSourceResult, .jsonNodeNotObject),
            };

            const json_node_outputs = switch (json_node.get("outputs") orelse empty_array) {
                .Array => |a| a,
                // FIXME: all of these return-err_explains do not errdefer-style deinit local data
                else => return err_explain(GraphToSourceResult, .jsonNodeOutputsNotArray)
            };

            if ((json_node.get("inputs") orelse empty_array) != .Array)
                return err_explain(GraphToSourceResult, .jsonNodeInputsNotArray);

            for (json_node_outputs.items) |json_output| {
                if (json_output != .Integer)
                    return err_explain(GraphToSourceResult, .jsonNodeOutputNotInteger);
                @setRuntimeSafety(false); // FIXME: weird pointer alignment error
                handle_src_node_map.put(json_output.Integer, &json_node_entry.value_ptr.Object)
                    catch |e| return GraphToSourceResult.fmt_err("{}", .{e}).toC();
            }
        }

        while (json_nodes_iter.next()) |json_node_entry| {
            const json_node = json_node_entry.value_ptr.Object;

            const is_root = if (json_node.get("outputs")) |outputs| outputs.Array.items.len == 0 else false;
            if (!is_root) continue;

            const Local = struct {
                fn recurseRootNodeToSexp(
                    in_json_node: json.ObjectMap,
                    alloc: std.mem.Allocator,
                    in_handle_src_node_map: std.AutoHashMap(i64, *const json.ObjectMap)
                ) Result(Sexp) {
                    // schema-checked in previous pass
                    const json_node_inputs = (in_json_node.get("inputs") orelse empty_array).Array;

                    var result = Sexp{.list = std.ArrayList(Sexp).init(alloc)};

                    const maybe_type = in_json_node.get("type");
                    if (maybe_type == null or maybe_type.? != .String)
                        return Result(Sexp).fmt_err("{}", .{error.jsonNodeTypeNotString});

                    const node_type = maybe_type.?.String;

                    // TODO: it is tempting to create a comptime function that constructs sexp from zig tuples
                    (result.list.addOne()
                        catch return err_explain(GraphToSourceResult, .OutOfMemory)
                    ).* = Sexp{.symbol = node_type};

                    // FIXME: handle literals...
                    for (json_node_inputs) |json_input| {
                        if (json_input != .Integer)
                            return Result(Sexp).fmt_err("{}", .{error.jsonNodeInputNotInteger});

                        const source_node = in_handle_src_node_map.get(json_input.Integer)
                            orelse return Result(Sexp).fmt_err("{}", .{error.undefinedInputHandle});

                        (result.*.list.addOne()
                            catch return Result(Sexp).fmt_err("{}", .{std.mem.Allocator.Error.OutOfMemory})
                        ).* = recurseRootNodeToSexp(source_node, alloc);
                    }

                    return Result(Sexp).ok(result);
                }
            };

            const maybe_sexp = Local.recurseRootNodeToSexp(json_node, arena_alloc, handle_src_node_map);
            if (maybe_sexp.is_err())
                return GraphToSourceResult.fmt_err("{s}", .{maybe_sexp.err}).toC();

            (node_exprs.addOne()
                catch return err_explain(GraphToSourceResult, .OutOfMemory)
            ).* = maybe_sexp.result;
        }

        for (node_exprs.items) |expr| {
            // FIXME: confirm to writer format/print API
            _ = expr.write(page_writer.writer())
                catch return err_explain(GraphToSourceResult, .ioErr);
            _ = page_writer.writer().write("\n")
                catch return err_explain(GraphToSourceResult, .ioErr);
        }
    }

    _ = page_writer.writer().write("\n")
        catch return err_explain(GraphToSourceResult, .ioErr);

    return GraphToSourceResult.ok(Slice.fromZig(
        // FIXME: make sure we can free this
        page_writer.concat(global_alloc.allocator())
            catch return err_explain(GraphToSourceResult, .OutOfMemory)
    )).toC();
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
    try testing.expectEqualStrings(
        source.buffer,
        Slice.toZig(result.result)
    );
}

export fn graph_to_source(graph_json: Slice) Result(Slice) {
    const zig_result = graphToSource(graph_json.toZig());
    return Result(Slice) {
        .result = Slice.fromZig(zig_result.result),
        .err = zig_result.err,
        .errCode = zig_result.errCode,
    };
}

test "source_to_graph" {
}


/// call c free on result
export fn source_to_graph(source: Slice) SourceToGraphResult {
    _ = source;
    return SourceToGraphResult.ok(Slice.fromZig("")).toC();
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

export fn readSrc(src: [*:0]const u8, in_status: ?*c_int) [*:0]const u8 {
    var ignored_status: c_int = 0;
    const out_status = in_status orelse &ignored_status;

    var page_writer = PageWriter.init(std.heap.page_allocator)
        catch { out_status.* = 1; return "Error: allocation err"; };
    defer page_writer.deinit();

    ide_json_gen.readSrc(global_alloc.allocator(), src[0..std.mem.len(src)], page_writer.writer())
        catch { out_status.* = 1; return "Error: parse error"; };

    page_writer.writer().writeByte(0)
        catch { out_status.* = 1; return "Error: write error"; };

    // FIXME: leak
    return @ptrCast([*:0]const u8, (
        page_writer.concat(global_alloc.allocator())
        catch { out_status.* = 1; return "Error: alloc concat error"; }
    ).ptr);
}

// TODO: only export in wasi
pub fn main() void {}

comptime {
    if (builtin.target.cpu.arch == .wasm32) {
        @export(alloc_string, .{ .name = "alloc_string", .linkage = .Strong });
        @export(free_string, .{ .name = "free_string", .linkage = .Strong });
    }
}
