const std = @import("std");
const builtin = @import("builtin");
const FileBuffer = @import("./FileBuffer.zig");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const io = std.io;
const testing = std.testing;
const json = std.json;

const innerParse = json.innerParse;
const innerParseFromValue = json.innerParseFromValue;

const JsonIntArrayHashMap = @import("./json_int_map.zig").IntArrayHashMap;

const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;
const ide_json_gen = @import("./ide_json_gen.zig");

const RearBitSubSet = @import("./RearBitSubSet.zig").RearBitSubSet;

// FIXME: rename
const Env = @import("./nodes/builtin.zig").Env;
const ExtraIndex = struct { index: usize };
const IndexedNode = @import("./nodes/builtin.zig").Node(ExtraIndex);
const IndexedLink = @import("./nodes/builtin.zig").Link(ExtraIndex);

test {
    _ = @import("./nodes/builtin.zig");
}

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


const JsonNode = struct {
    type: []const u8,
    inputs: []const ?JsonNodeInput = &.{},
    outputs: []const JsonNodeOutput = &.{},
    // FIXME: create zig type json type that treats optionals not as possibly null but as possibly missing
    data: struct {
        isEntry: bool = false,
        comment: ?[]const u8 = null
    },

    pub fn toEmptyNode(self: @This(), env: Env, index: usize) !IndexedNode {
        var node = env.makeNode(self.type, ExtraIndex{ .index = index })
            orelse return error.UnknownNodeType;
        // NOTE: should probably add ownership to json parsed strings so we can deallocate some...
        node.comment = self.data.comment;
        return node;
    }
};

const Import = struct {
    ref: []const u8,
    alias: ?[]const u8,
};

const empty_imports = json.ArrayHashMap([]const Import){};

const GraphDoc = struct {
    nodes: JsonIntArrayHashMap(i64, JsonNode, 10),
    imports: json.ArrayHashMap([]const Import) = empty_imports,
};

const GraphBuilder = struct {
    env: Env,
    // FIXME: add an optional debug step to verify topological order
    /// map of json node ids to its real node,
    /// in topological order!
    nodes: JsonIntArrayHashMap(i64, IndexedNode, 10) = .{},
    alloc: std.mem.Allocator,
    err_alloc: std.mem.Allocator = global_alloc, // this must be freeable by exported API users
    branch_joiner_map: std.AutoHashMapUnmanaged(*const IndexedNode, *const IndexedNode) = .{},
    entry: ?*const IndexedNode = null,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, env: Env) Self {
        return Self {
            .env = env,
            .alloc = alloc,
        };
    }

    pub fn getSingleExecFromEntry(entry: *const IndexedNode) Result(IndexedLink) {
        var entry_exec = Result(IndexedLink).err("No exec pins on entry node");
        for (entry.out_links, 0..) |out_link, i| {
            const out_pin = entry.desc.getOutputs()[i];
            if (out_pin == .exec) {
                if (entry_exec.is_ok()) {
                    entry_exec = Result(IndexedLink).err("Multiple exec pins on entry node");
                    return entry_exec;
                }
                entry_exec = Result(IndexedLink).ok(out_link);
            }
        }
        return entry_exec;
    }

    pub fn buildFromJson(
        self: *Self,
        json_graph: GraphDoc,
    ) Result(void) {
        const entry_result = self.populateAndReturnEntry(json_graph);
        if (entry_result.is_err()) return entry_result.err_as(void);
        // PLEASE RENAME TO .value
        const entry = if (entry_result.is_err())
            return entry_result.err_as(void)
            else entry_result.result;

        self.entry = entry;

        const link_result = self.link(json_graph);
        if (link_result.is_err()) return link_result;

        const exec_handle_result = Self.getSingleExecFromEntry(entry);
        const exec_handle = if (exec_handle_result.is_err()) return exec_handle_result.err_as(void) else exec_handle_result.result;
        _ = exec_handle;

        return Result(void).ok({});
    }

    pub fn populateAndReturnEntry(
        self: *Self,
        json_graph: GraphDoc,
    ) Result(*const IndexedNode) {
        var entry_id: ?i64 = null;
        var result = Result(*const IndexedNode).err("JSON graph contains no entry");
        // FIXME: this belongs in buildFromJson...
        defer if (result.is_err()) self.nodes.map.clearAndFree(self.alloc);

        var branch_count: u32 = 0;
        var node_index: usize = 0;

        var json_nodes_iter = json_graph.nodes.map.iterator();
        while (json_nodes_iter.next()) |node_entry| {
            const node_id = node_entry.key_ptr.*;
            // FIXME: accidental copy?
            const json_node = node_entry.value_ptr.*;

            const node = json_node.toEmptyNode(self.env, node_index) catch |e| {
                result = Result(*const IndexedNode).fmt_err(self.err_alloc, "{}: for node type: {s}", .{e, json_node.type});
                return result;
            };

            const putResult = self.nodes.map.getOrPut(self.alloc, node_id)
                catch |e| { result = Result(*const IndexedNode).fmt_err(self.err_alloc, "{}", .{e}); return result; };

            putResult.value_ptr.* = node;

            if (putResult.found_existing) {
                result = Result(*const IndexedNode).fmt_err(self.err_alloc, "Illegal duplicate node in graph", .{});
                return result;
            }

            if (json_node.data.isEntry) {
                if (entry_id != null) {
                    result = Result(*const IndexedNode).fmt_err(
                        self.err_alloc,
                        "JSON graph contains more than 1 entry, second entry has id '{}'",
                        .{node_id}
                    );
                    return result;
                }
                entry_id = node_id;
            }

            // FIXME: a more sophisticated check for if it's a branch, including macro expansion
            const is_branch = std.mem.eql(u8, json_node.type, "if");
            if (is_branch)
                branch_count += 1;

            node_index += 1;
        }

        if (entry_id) |id| {
            result = Result(*const IndexedNode).ok(self.nodes.map.getPtr(id) orelse unreachable);

            self.branch_joiner_map.ensureTotalCapacity(self.alloc, branch_count)
                catch |e| { result = Result(*const IndexedNode).fmt_err(self.err_alloc, "{}", .{e}); return result; };
        }

        return result;
    }

    pub fn link(self: @This(), graph_json: GraphDoc) Result(void) {
        var nodes_iter = self.nodes.map.iterator();
        var json_nodes_iter = graph_json.nodes.map.iterator();
        std.debug.assert(nodes_iter.len == json_nodes_iter.len);

        while (true) {
            const node_entry = nodes_iter.next() orelse break;
            const node = node_entry.value_ptr;

            const json_node_entry = json_nodes_iter.next() orelse unreachable;
            const json_node = json_node_entry.value_ptr;

            self.linkNode(json_node.*, node)
                catch |e| return Result(void).fmt_err(global_alloc, "{}", .{e});
        }

        return Result(void).ok({});
    }

    /// link with other empty nodes in a graph
    pub fn linkNode(self: @This(), json_node: JsonNode, node: *IndexedNode) !void {
        node.out_links = try self.alloc.alloc(IndexedLink, json_node.outputs.len);
        errdefer self.alloc.free(node.out_links);
        for (node.out_links, json_node.outputs) |*out_link, json_output| {
            if (json_output != .handle)
                continue;
            out_link.* = IndexedLink{
                .target = self.nodes.map.getPtr(json_output.handle.nodeId) orelse return error.LinkToUnknownNode,
                .pin_index = json_output.handle.handleIndex,
            };
        }
    }

    const NodeAnalysisResult = struct {
        visited: u1 = 0,
    };

    /// context for analyzing an output-directed cyclic subtree of a graph rooted by a branch
    const AnalysisCtx = struct {
        node_data: std.MultiArrayList(NodeAnalysisResult) = .{},

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            self.node_data.deinit(alloc);
        }
    };

    // NOTE: stack-space-bound
    // To find the join of a branch, find all reachable end nodes
    // if there is only 1, it joins.
    // How to deal with inner branches: - If we encounter a branch within a branch, solve the inner branch first.
    // - If it doesn't join, neither does the super branch
    // - But if it does, that doesn't help us find the outer join node

    /// each branch will may have 1 (or 0) join node where the control flow for that branch converges
    /// first traverse all nodes getting for each its single end (or null if multiple), and its tree size
    pub fn analyzeNodes(self: @This()) Result(void) {
        var result = Result(void).ok({});
        defer if (result.is_err()) self.branch_joiner_map.clearAndFree(self.alloc);

        var analysis_ctx: AnalysisCtx = .{};
        defer analysis_ctx.deinit(self.alloc);


        analysis_ctx.node_data.resize(self.alloc, self.nodes.map.count())
            catch |e| { result = Result(void).fmt_err(global_alloc, "{}", .{e}); return result; };

        // initialize with empty data
        var slices = analysis_ctx.node_data.slice();
        @memset(slices.items(.visited)[0..analysis_ctx.node_data.len], 0);

        var node_iter = self.nodes.map.iterator();
        while (node_iter) |node| {
            // inlined analyzeNode precondition because not sure with recursion compiler can figure it out
            if (analysis_ctx.node_data.items(.visited)[node.extra.index])
                continue;

            const node_result = self.analyzeNode(node, analysis_ctx);
            if (node_result.is_err()) { result = node_result; return node_result; }
        }

        return result;
    }

    fn analyzeNode(
        self: @This(),
        node: *const IndexedNode,
        analysis_ctx: *AnalysisCtx,
    ) Result(void) {
        if (analysis_ctx.node_data.items(.visited)[node.extra.index])
            return .{};
        analysis_ctx.node_data.items(.visited)[node.extra.index] = 1;

        const is_branch = std.mem.eql(u8, node.desc.name, "if");

        if (is_branch)
            _ = self.analyzeBranch(node, analysis_ctx);

        return .{};
    }

    fn analyzeBranch(
        self: @This(),
        branch: *const IndexedNode,
        analysis_ctx: *AnalysisCtx,
    ) Result(?*const IndexedNode) {
        if (analysis_ctx.node_data.items(.visited)[branch.index]) {
            const prev_result = self.branch_joiner_map.get(branch.index);
            return .{ .result = prev_result };
        }

        analysis_ctx.node_data.items(.visited)[branch.index] = 1;

        const result = self.doAnalyzeBranch(branch, analysis_ctx);

        if (result.is_ok())
            self.branch_joiner_map.put(result.result)
                catch |e| return Result(?*const IndexedNode).fmt_err(global_alloc, "{}", .{e});

        return result;
    }

    // FIXME: handle macros, switches, etc
    // FIXME: prove the following, write down somewhere
    // NOTE: all multi-exec-input nodes necessarily are macros that just expand to single-exec-input nodes
    /// @returns the joining node for the branch, or null if it doesn't join
    fn doAnalyzeBranch(
        self: @This(),
        branch: *const IndexedNode,
        analysis_ctx: *AnalysisCtx,
    ) Result(?*const IndexedNode) {
        if (analysis_ctx.node_data.items(.visited)[branch.index]) {
            const prev_result = self.branch_joiner_map.get(branch.index);
            return .{ .result = prev_result };
        }

        analysis_ctx.node_data.items(.visited)[branch.index] = 1;

        var collapsed_node_layer = std.AutoArrayHashMapUnmanaged(*const IndexedNode, {});
        collapsed_node_layer.put(branch)
            catch |e| return Result(?*const IndexedNode).fmt_err(global_alloc, "{}", .{e});
        defer collapsed_node_layer.deinit(self.alloc);

        while (true) {
            var new_collapsed_node_layer = std.AutoArrayHashMapUnmanaged(*const IndexedNode, {});

            for (collapsed_node_layer.items()) |collapsed_node| {
                const is_branch = std.mem.eql(u8, collapsed_node.desc.name, "if");

                if (is_branch) {
                    const joiner = self.analyzeBranch(collapsed_node, analysis_ctx);
                    if (joiner.is_err() || joiner.result == null)
                        return joiner
                    else
                        new_collapsed_node_layer.put(joiner.result)
                            catch |e| return Result(?*const IndexedNode).fmt_err(global_alloc, "{}", .{e});
                } else {
                    var exec_link_iter = collapsed_node.iter_out_exec_links();
                    while (exec_link_iter.next()) |exec_link| {
                        new_collapsed_node_layer.put(exec_link.target)
                            catch |e| return Result(?*const IndexedNode).fmt_err(global_alloc, "{}", .{e});
                    }
                }
            }

            const new_layer_count = new_collapsed_node_layer.count();

            if (new_layer_count == 0)
                return .{ .result = null };
            if (new_layer_count == 1)
                return .{ .result = new_collapsed_node_layer.iterator.next() orelse unreachable };

            collapsed_node_layer.clearAndFree(self.alloc);
            // FIXME: what happens if we error before this swap? need an errdefer...
            collapsed_node_layer = new_collapsed_node_layer; // FIXME: ummm doesn't this introduce a free?
        }
    }

    fn toSexp(self: @This(), node: *const IndexedNode) Result(Sexp) {
        var result = Sexp{ .list = std.ArrayList(Sexp).init(self.alloc) };
        _ = node;

        // // TODO: it is tempting to create a comptime function that constructs sexp from zig tuples
        (result.list.addOne()
            catch |e| return Result(Sexp).fmt_err(global_alloc, "{}", .{e})
        ).* = Sexp{ .symbol = node.type };

        // FIXME: handle literals...
        for (node.inputs) |input| {
            //if (input != .pin)
                //@panic("not yet supported!");

            const source_node = handle_srcnode_map.get(input)
                orelse return Result(Sexp).fmt_err(global_alloc, "{} (handle {})",
                    .{ error.undefinedInputHandle, input });

            const next = self.buildFromJsonEntry(source_node.*, alloc);
            if (next.is_err())
                return next;

            (result.list.addOne()
                catch |e| return Result(Sexp).fmt_err(global_alloc, "{}", .{e})
            ).* = next.result;
        }

        return Result(Sexp).ok(result);
    }

    pub fn rootToSexp(self: @This()) Result(Sexp) {
        return if (self.entry) |entry|
            self.toSexp(entry)
        else
            Result(Sexp).fmt_err(global_alloc, "no entry or not yet set", .{});
    }
};

/// caller must free result with {TBD}
fn graphToSource(graph_json: []const u8) GraphToSourceResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var env = Env.initDefault(arena_alloc)
        catch |e| return GraphToSourceResult.fmt_err(global_alloc, "{}", .{e});

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

    var builder = GraphBuilder.init(arena_alloc, env);
    const build_result = builder.buildFromJson(graph);
    if (build_result.is_err()) return build_result.err_as([]const u8);

    const sexp_result = builder.rootToSexp();
    const sexp = if (sexp_result.is_ok()) sexp_result.result else return sexp_result.err_as([]const u8);

    _ = sexp.write(page_writer.writer()) catch return err_explain(GraphToSourceResult, .ioErr);
    _ = page_writer.writer().write("\n") catch return err_explain(GraphToSourceResult, .ioErr);

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
const global_alloc = global_allocator_inst.allocator();

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
