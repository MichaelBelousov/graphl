const std = @import("std");
const builtin = @import("builtin");
const FileBuffer = @import("./FileBuffer.zig");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const testing = std.testing;
const json = std.json;

const JsonIntArrayHashMap = @import("./json_int_map.zig").IntArrayHashMap;

const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;

const Env = @import("./nodes/builtin.zig").Env;
const Value = @import("./nodes/builtin.zig").Value;

const debug_tail_call = @import("./common.zig").debug_tail_call;
const global_alloc = @import("./common.zig").global_alloc;
const GraphTypes = @import("./common.zig").GraphTypes;
const IndexedNode = GraphTypes.Node;
const IndexedLink = GraphTypes.Link;

const Slice = @import("./slice.zig").Slice;

const JsonNodeHandle = @import("./json_format.zig").JsonNodeHandle;
const JsonNodeInput = @import("./json_format.zig").JsonNodeInput;
const JsonNode = @import("./json_format.zig").JsonNode;
const Import = @import("./json_format.zig").Import;
const GraphDoc = @import("./json_format.zig").GraphDoc;

const GraphBuilder = struct {
    env: Env,
    // FIXME: does this need to be in topological order? Is that advantageous?
    /// map of json node ids to its real node,
    nodes: JsonIntArrayHashMap(i64, IndexedNode, 10) = .{},
    alloc: std.mem.Allocator,
    err_alloc: std.mem.Allocator = global_alloc, // TODO: this must be freeable by exported API users
    // FIXME: fill the analysis context instead of keeping this in the graph metadata itself
    branch_joiner_map: std.AutoHashMapUnmanaged(*const IndexedNode, *const IndexedNode) = .{},
    is_join_set: std.DynamicBitSetUnmanaged,
    entry: ?*const IndexedNode = null,

    const Self = @This();
    const Types = GraphTypes;

    pub fn isJoin(self: @This(), node: *const IndexedNode) bool {
        return self.is_join_set.isSet(node.extra.index);
    }

    // FIXME: remove buildFromJson and just do it all in init?
    pub fn init(alloc: std.mem.Allocator, env: Env) !Self {
        return Self{
            .env = env,
            .alloc = alloc,
            .is_join_set = try std.DynamicBitSetUnmanaged.initEmpty(alloc, 0),
        };
    }

    pub fn getSingleExecFromEntry(entry: *const IndexedNode) !GraphTypes.Output {
        var entry_exec = error.EntryNodeNoExecPins;
        for (entry.outputs, 0..) |output, i| {
            const out_type = entry.desc.getOutputs()[i];
            if (out_type == .primitive and out_type.primitive == .exec) {
                if (entry_exec.is_ok()) {
                    entry_exec = error.ExecNodeMultiExecPin;
                    return entry_exec;
                }
                entry_exec = output;
            }
        }
        return entry_exec;
    }

    pub fn buildFromJson(
        self: *Self,
        json_graph: GraphDoc,
    ) !void {
        const entry = try self.populateAndReturnEntry(json_graph);
        self.entry = entry;
        try self.link(json_graph);
    }

    pub const PopulateAndReturnEntryDiagnostic = union(enum) {
        DuplicateNode: i64,
        MultipleEntries: i64,
    };

    pub fn populateAndReturnEntry(
        self: *Self,
        json_graph: GraphDoc,
        diagnostic: ?*PopulateAndReturnEntryDiagnostic,
    ) !*const IndexedNode {
        var entry_id: ?i64 = null;
        var result = error.GraphHasNoEntry;

        // FIXME: this belongs in buildFromJson...
        errdefer self.nodes.map.clearAndFree(self.alloc);

        var branch_count: u32 = 0;
        var node_index: usize = 0;

        var json_nodes_iter = json_graph.nodes.map.iterator();
        while (json_nodes_iter.next()) |node_entry| {
            const node_id = node_entry.key_ptr.*;
            // FIXME: accidental copy?
            const json_node = node_entry.value_ptr.*;

            const node = try json_node.toEmptyNode(self.env, node_index);

            const putResult = try self.nodes.map.getOrPut(self.alloc, node_id);

            putResult.value_ptr.* = node;

            if (putResult.found_existing) {
                if (diagnostic) |d| d.* = node_id;
                return error.DuplicateNode;
            }

            if (json_node.data.isEntry) {
                if (entry_id != null) {
                    if (diagnostic) |d| d.* = node_id;
                    return error.MultipleEntries;
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
            // FIXME: confirm why this is unreachable
            result = self.nodes.map.getPtr(id) orelse unreachable;
            try self.branch_joiner_map.ensureTotalCapacity(self.alloc, branch_count);
            try self.is_join_set.resize(self.alloc, self.nodes.map.count(), false);
        }

        return result;
    }

    pub fn link(self: @This(), graph_json: GraphDoc) !void {
        var nodes_iter = self.nodes.map.iterator();
        var json_nodes_iter = graph_json.nodes.map.iterator();
        std.debug.assert(nodes_iter.len == json_nodes_iter.len);

        while (true) {
            const node_entry = nodes_iter.next() orelse break;
            const node = node_entry.value_ptr;

            const json_node_entry = json_nodes_iter.next() orelse unreachable;
            const json_node = json_node_entry.value_ptr;

            try self.linkNode(json_node.*, node);
        }
    }

    /// link with other empty nodes in a graph
    pub fn linkNode(self: @This(), json_node: JsonNode, node: *IndexedNode) !void {
        node.inputs = try self.alloc.alloc(GraphTypes.Input, json_node.inputs.len);
        errdefer self.alloc.free(node.inputs);

        for (node.inputs, json_node.inputs) |*input, maybe_json_input| {
            input.* = switch (maybe_json_input orelse JsonNodeInput{ .value = .null }) {
                .handle => |h| .{ .link = .{
                    .target = self.nodes.map.getPtr(h.nodeId) orelse return error.LinkToUnknownNode,
                    .pin_index = h.handleIndex,
                } },
                .value => |v| .{ .value = v },
            };
        }

        node.outputs = try self.alloc.alloc(?GraphTypes.Output, json_node.outputs.len);
        errdefer self.alloc.free(node.outputs);

        for (node.outputs, json_node.outputs) |*output, maybe_json_output| {
            output.* = if (maybe_json_output) |json_output| .{ .link = .{
                .target = self.nodes.map.getPtr(json_output.nodeId) orelse return error.LinkToUnknownNode,
                .pin_index = json_output.handleIndex,
            } } else null;
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
    pub fn analyzeNodes(self: @This()) void {
        errdefer self.branch_joiner_map.clearAndFree(self.alloc);
        errdefer self.is_join_set.deinit(self.alloc);

        var analysis_ctx: AnalysisCtx = .{};
        defer analysis_ctx.deinit(self.alloc);

        try analysis_ctx.node_data.resize(self.alloc, self.nodes.map.count());

        // initialize with empty data
        var slices = analysis_ctx.node_data.slice();
        @memset(slices.items(.visited)[0..analysis_ctx.node_data.len], 0);

        const node_iter = self.nodes.map.iterator();
        while (node_iter.next()) |node| {
            // inlined analyzeNode precondition because not sure with recursion compiler can figure it out
            if (analysis_ctx.node_data.items(.visited)[node.extra.index])
                continue;

            try self.analyzeNode(node, analysis_ctx);
        }
    }

    fn analyzeNode(
        self: @This(),
        node: *const IndexedNode,
        analysis_ctx: *AnalysisCtx,
    ) void {
        if (analysis_ctx.node_data.items(.visited)[node.extra.index])
            return;

        analysis_ctx.node_data.items(.visited)[node.extra.index] = 1;

        const is_branch = std.mem.eql(u8, node.desc.name, "if");

        if (is_branch)
            _ = self.analyzeBranch(node, analysis_ctx);
    }

    fn analyzeBranch(
        self: @This(),
        branch: *const IndexedNode,
        analysis_ctx: *AnalysisCtx,
    ) ?*const IndexedNode {
        if (analysis_ctx.node_data.items(.visited)[branch.index]) {
            const prev_result = self.branch_joiner_map.get(branch.index);
            return .{ .value = prev_result };
        }

        analysis_ctx.node_data.items(.visited)[branch.index] = 1;

        const result = self.doAnalyzeBranch(branch, analysis_ctx);

        if (result.is_ok()) {
            const value = result.value;
            try self.branch_joiner_map.put(value);
            self.is_join_set.set(value.extra.index, true);
        }

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
    ) ?*const IndexedNode {
        if (analysis_ctx.node_data.items(.visited)[branch.index]) {
            const prev_result = self.branch_joiner_map.get(branch.index);
            return .{ .value = prev_result };
        }

        analysis_ctx.node_data.items(.visited)[branch.index] = 1;

        var collapsed_node_layer = std.AutoArrayHashMapUnmanaged(*const IndexedNode, {});
        try collapsed_node_layer.put(branch);
        defer collapsed_node_layer.deinit(self.alloc);

        while (true) {
            var new_collapsed_node_layer = std.AutoArrayHashMapUnmanaged(*const IndexedNode, {});

            for (collapsed_node_layer.items()) |collapsed_node| {
                const is_branch = std.mem.eql(u8, collapsed_node.desc.name, "if");

                if (is_branch) {
                    const joiner = self.analyzeBranch(collapsed_node, analysis_ctx);
                    if (joiner.is_err() || joiner.value == null)
                        return joiner
                    else
                        try new_collapsed_node_layer.put(joiner.value);
                } else {
                    var exec_link_iter = collapsed_node.iter_out_exec_links();
                    while (exec_link_iter.next()) |exec_link| {
                        try new_collapsed_node_layer.put(exec_link.target);
                    }
                }
            }

            const new_layer_count = new_collapsed_node_layer.count();

            if (new_layer_count == 0)
                return .{ .value = null };
            if (new_layer_count == 1)
                return .{ .value = new_collapsed_node_layer.iterator.next() orelse unreachable };

            collapsed_node_layer.clearAndFree(self.alloc);
            // FIXME: what happens if we error before this swap? need an errdefer...
            collapsed_node_layer = new_collapsed_node_layer; // FIXME: ummm doesn't this introduce a free?
        }
    }

    /// overall algorithm:
    /// 1. allocate a "block" for the path
    /// 2. traverse the exec tree starting at the entry, stopping before any join nodes
    /// 3. when encountering a branch, recurse on the paths starting with the consequence and alternative
    ///    to build the branch expression, then continue the path starting from its join
    const ToSexp = struct {
        graph: *const GraphBuilder,

        const NodeData = struct {
            visited: u1,
        };

        // must be same as sexp...
        const Block = std.ArrayList(Sexp);

        const Context = struct {
            node_data: std.MultiArrayList(NodeData) = .{},
            block: Block,
        };

        pub fn toSexp(self: @This(), node: *const IndexedNode) Sexp {
            var ctx = Context{
                .block = Block.init(self.graph.alloc),
            };
            try ctx.node_data.resize(self.graph.alloc, self.graph.nodes.map.count());
            const result = self.onNode(node, &ctx);
            if (result.is_err()) return result.err_as(Sexp);
            return Sexp{ .value = .{ .list = ctx.block } };
        }

        pub fn onNode(self: @This(), node: *const IndexedNode, context: *Context) void {
            // FIXME: not handled
            if (context.node_data.items(.visited)[node.extra.index] == 1)
                return error.CyclesNotSupported;

            context.node_data.items(.visited)[node.extra.index] = 1;

            return if (node.desc.isSimpleBranch())
                @call(debug_tail_call, onBranchNode, .{ self, node, context })
            else
                @call(debug_tail_call, onFunctionCallNode, .{ self, node, context });
        }

        // FIXME: refactor to find joins during this?
        pub fn onBranchNode(self: @This(), node: *const IndexedNode, context: *Context) void {
            std.debug.assert(node.desc.isSimpleBranch());

            var consequence_sexp: Sexp = undefined;
            var alternative_sexp: Sexp = undefined;

            if (node.outputs[0]) |consequence| {
                var consequence_ctx = Context{
                    .node_data = context.node_data,
                    .block = Block.init(self.graph.alloc),
                };
                // FIXME: only add `begin` if it's multiple expressions
                (try consequence_ctx.block.addOne()).* = syms.begin;
                try self.onNode(consequence.link.target, &consequence_ctx);
                consequence_sexp = Sexp{ .value = .{ .list = consequence_ctx.block } };
            }

            if (node.outputs[1]) |alternative| {
                var alternative_ctx = Context{
                    .node_data = context.node_data,
                    .block = Block.init(self.graph.alloc),
                };
                // FIXME: only add `begin` if it's multiple expressions
                (try alternative_ctx.block.addOne()).* = syms.begin;
                try self.onNode(alternative.link.target, &alternative_ctx);
                alternative_sexp = Sexp{ .value = .{ .list = alternative_ctx.block } };
            }

            var branch_sexp = try context.block.addOne();

            // FIXME: errdefer, maybe just force an arena and call it a day?
            branch_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.graph.alloc) } };

            // (if
            (try branch_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = node.desc.name } };

            // condition
            const condition_result = self.nodeInputTreeToSexp(node.inputs[1]);
            const condition_sexp = if (condition_result.is_ok()) condition_result.value else return condition_result.err_as(void);
            (try branch_sexp.value.list.addOne()).* = condition_sexp;

            // FIXME: wish I could make this terser...
            (try branch_sexp.value.list.addOne()).* = consequence_sexp;

            // alternative
            (try branch_sexp.value.list.addOne()).* = alternative_sexp;

            if (self.graph.branch_joiner_map.get(node)) |join| {
                return @call(debug_tail_call, onNode, .{ self, join, context });
            }
        }

        pub fn onFunctionCallNode(self: @This(), node: *const IndexedNode, context: *Context) void {
            if (self.graph.isJoin(node))
                return;

            var call_sexp = try context.block.addOne();

            // FIXME: errdefer
            call_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.graph.alloc) } };

            (try call_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = node.desc.name } };

            if (builtin.mode == .Debug and node.inputs.len == 0) {
                std.debug.print("no inputs, desc: {s}\n", .{node.desc.name});
            }

            for (node.inputs[1..]) |input| {
                const input_tree_result = self.nodeInputTreeToSexp(input);
                const input_tree = if (input_tree_result.is_ok()) input_tree_result.value else return input_tree_result.err_as(void);
                (try call_sexp.value.list.addOne()).* = input_tree;
            }

            if (builtin.mode == .Debug and node.outputs.len == 0) {
                std.debug.print("no outputs, desc: {s}\n", .{node.desc.name});
            }

            if (node.outputs[0]) |next| {
                return @call(debug_tail_call, onNode, .{ self, next.link.target, context });
            }
        }

        fn nodeInputTreeToSexp(self: @This(), in_link: GraphTypes.Input) Sexp {
            const sexp = switch (in_link) {
                .link => |v| _: {
                    // TODO: it is tempting to create a comptime function that constructs sexp from zig tuples
                    var result = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.graph.alloc) } };

                    const node = v.target;

                    try result.value.list.ensureTotalCapacityPrecise(node.inputs.len + 1);

                    // FIXME: for this case add a from_err helper?
                    // and maybe c_from_err too to set allocator automatically?
                    (try result.value.list.addOne()).* = Sexp{ .value = .{ .symbol = node.desc.name } };

                    for (node.inputs) |input| {
                        (try result.value.list.addOne()).* = try self.nodeInputTreeToSexp(input);
                    }

                    break :_ result;
                },
                // FIXME: move to own func for Value=>Sexp?, or just make Value==Sexp now...
                .value => |v| switch (v) {
                    .number => |u| Sexp{ .value = .{ .float = u } },
                    .string => |u| Sexp{ .value = .{ .borrowedString = u } },
                    .bool => |u| Sexp{ .value = .{ .bool = u } },
                    .null => Sexp{ .value = .void },
                    .symbol => |u| Sexp{ .value = .{ .symbol = u } },
                },
            };

            return sexp;
        }
    };

    pub fn rootToSexp(self: @This()) Sexp {
        return if (self.entry) |entry|
            if (entry.outputs[0]) |first_node|
                (ToSexp{ .graph = &self }).toSexp(first_node.link.target)
            else
                Sexp{ .value = .void }
        else
            error.NoEntryOrNotYetSet;
    }
};

const GraphToSourceErr = union(enum) {
    None,
    IoErr: anyerror,
    OutOfMemory: void,

    const Code = error{
        IoErr,
        OutOfMemory,
    };

    pub fn from(err: error.OutOfMemory) GraphToSourceErr {
        return switch (err) {
            error.OutOfMemory => GraphToSourceErr{ .OutOfMemory = {} },
        };
    }

    pub fn code(self: @This()) Code {
        switch (self) {
            .IoErr => Code.IoErr,
            .OutOfMemory => Code.OutOfMemory,
        }
    }

    pub fn format(
        self: @This(),
        comptime fmt_str: []const u8,
        fmt_opts: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt_str;
        _ = fmt_opts;
        switch (self) {
            .IoErr => |e| try writer.print("IO Error ({})", .{e}),
            .OutOfMemory => try writer.print("Out of memory", .{}),
        }
    }
};

const GraphToSourceDiagnostic = GraphToSourceErr;

/// caller must free result with {TBD}
fn graphToSource(graph_json: []const u8, diagnostic: ?*GraphToSourceDiagnostic) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const env = try Env.initDefault(arena_alloc);

    var json_diagnostics = json.Diagnostics{};
    var graph_json_reader = json.Scanner.initCompleteInput(arena_alloc, graph_json);
    graph_json_reader.enableDiagnostics(&json_diagnostics);
    const graph = try json.parseFromTokenSourceLeaky(GraphDoc, arena_alloc, &graph_json_reader, .{
        .ignore_unknown_fields = true,
    });

    var page_writer = try PageWriter.init(std.heap.page_allocator);
    defer page_writer.deinit();

    var import_exprs = std.ArrayList(Sexp).init(arena_alloc);
    defer import_exprs.deinit();
    try import_exprs.ensureTotalCapacityPrecise(graph.imports.map.count());

    // TODO: refactor blocks into functions
    {
        {
            var imports_iter = graph.imports.map.iterator();
            while (imports_iter.next()) |json_import_entry| {
                const json_import_name = json_import_entry.key_ptr.*;
                const json_import_bindings = json_import_entry.value_ptr.*;

                const new_import = try import_exprs.addOne();

                // TODO: it is tempting to create a comptime function that constructs sexp from zig tuples
                new_import.* = Sexp{
                    .value = .{ .list = std.ArrayList(Sexp).init(arena_alloc) },
                };
                (try new_import.*.value.list.addOne()).* = syms.import;
                (try new_import.*.value.list.addOne()).* = Sexp{ .value = .{ .symbol = json_import_name } };

                const imported_bindings = try new_import.*.value.list.addOne();
                imported_bindings.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(arena_alloc) } };

                for (json_import_bindings) |json_imported_binding| {
                    const ref = json_imported_binding.ref;
                    const added = try imported_bindings.*.value.list.addOne();

                    if (json_imported_binding.alias) |alias| {
                        (try added.*.value.list.addOne()).* = syms.as;
                        (try added.*.value.list.addOne()).* = Sexp{ .value = .{ .symbol = ref } };
                        (try added.*.value.list.addOne()).* = Sexp{ .value = .{ .symbol = alias } };
                    } else {
                        added.* = Sexp{ .value = .{ .symbol = ref } };
                    }
                }
            }
        }

        for (import_exprs.items) |import| {
            _ = import.write(page_writer.writer()) catch |e| return {
                if (diagnostic) |d| d.* = .{ .IoErr = e };
                return e;
            };
            _ = try page_writer.writer().write("\n");
        }
    }

    var builder = try GraphBuilder.init(arena_alloc, env);
    const build_result = try builder.buildFromJson(graph, if (diagnostic) |d| &d.BuildError else null);
    if (build_result.is_err()) return build_result.err_as([]const u8);

    const sexp_result = builder.rootToSexp();
    const sexp = if (sexp_result.is_ok()) sexp_result.value else return sexp_result.err_as([]const u8);

    switch (sexp.value) {
        .list => |l| {
            for (l.items) |s| {
                _ = try s.write(page_writer.writer());
                _ = try page_writer.writer().write("\n");
            }
        },
        else => {
            _ = try sexp.write(page_writer.writer());
            _ = try page_writer.writer().write("\n");
        },
    }

    _ = try page_writer.writer().write("\n");

    // FIXME: provide API to free this
    return page_writer.concat(global_alloc);
}

test "big graph_to_source" {
    const alloc = std.testing.allocator;
    const source = try FileBuffer.fromDirAndPath(alloc, std.fs.cwd(), "./tests/small1/source.scm");
    defer source.free(alloc);
    const graph_json = try FileBuffer.fromDirAndPath(alloc, std.fs.cwd(), "./tests/small1/graph.json");
    defer graph_json.free(alloc);

    // NOTE: it is extremely vague how we're going to isomorphically convert
    // variable definitions... can variables be declared at any point in the node graph?
    // will scoping be function-level?
    // Does synchronizing graph changes into the source affect those?

    const result = graph_to_source(graph_json.buffer);
    if (result) |value| {
        try testing.expectEqualStrings(source.buffer, value);
    } else |err| {
        std.debug.print("\n{?s}\n", .{err});
        return error.FailTest;
    }
}

export fn graph_to_source(graph_json: []const u8) []const u8 {
    return graphToSource(graph_json.toZig());
}
