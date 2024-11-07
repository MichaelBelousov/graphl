const std = @import("std");
const builtin = @import("builtin");
const FileBuffer = @import("./FileBuffer.zig");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const testing = std.testing;
const json = std.json;

const JsonIntArrayHashMap = @import("./json_int_map.zig").IntArrayHashMap;

const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;
const primitive_type_syms = @import("./sexp.zig").primitive_type_syms;

const Env = @import("./nodes/builtin.zig").Env;
const Type = @import("./nodes/builtin.zig").Type;
const Value = @import("./nodes/builtin.zig").Value;

const debug_tail_call = @import("./common.zig").debug_tail_call;
const global_alloc = @import("./common.zig").global_alloc;
const GraphTypes = @import("./common.zig").GraphTypes;

// TODO: rename
const IndexedNode = GraphTypes.Node;
const IndexedLink = GraphTypes.Link;

const Slice = @import("./slice.zig").Slice;

const JsonNodeHandle = @import("./json_format.zig").JsonNodeHandle;
const JsonNodeInput = @import("./json_format.zig").JsonNodeInput;
const JsonNode = @import("./json_format.zig").JsonNode;
const Import = @import("./json_format.zig").Import;
const GraphDoc = @import("./json_format.zig").GraphDoc;
const debug_print = @import("./debug_print.zig").debug_print;

pub const ImportBinding = struct {
    binding: []const u8,
    alias: ?[]const u8,
};

// FIXME: deprecate, access this directly
pub const NodeId = GraphTypes.NodeId;

pub const Binding = struct {
    name: []u8,
    type_: Type,
    comment: ?[]u8 = null,
};

/// all APIs taking an allocator must use the same allocator
pub const GraphBuilder = struct {
    // FIXME: then make it a pointer!
    // we do not own this, it is just referenced
    env: Env,
    // FIXME: does this need to be in topological order? Is that advantageous?
    /// map of json node ids to its real node,
    nodes: JsonIntArrayHashMap(NodeId, IndexedNode, 10) = .{},
    // FIXME: fill the analysis context instead of keeping this in the graph metadata itself
    branch_joiner_map: std.AutoHashMapUnmanaged(*const IndexedNode, *const IndexedNode) = .{},
    is_join_set: std.DynamicBitSetUnmanaged,
    entry_id: ?NodeId = null,
    return_node_id: ?NodeId = null,
    branch_count: u32 = 0,
    next_node_index: usize = 0,

    // FIXME: who owns these?
    imports: std.ArrayListUnmanaged(Sexp) = .{},
    locals: std.ArrayListUnmanaged(Binding) = .{},
    params: std.ArrayListUnmanaged(Binding) = .{},
    results: std.ArrayListUnmanaged(Binding) = .{},

    const Self = @This();
    const Types = GraphTypes;

    pub fn entry(self: *const @This()) ?*IndexedNode {
        return if (self.entry_id) |entry_id| self.nodes.map.getPtr(entry_id) orelse unreachable else null;
    }

    // FIXME: replace pointers with indices into an allocator? Could be faster
    pub fn isJoin(self: @This(), node: *const IndexedNode) bool {
        return self.is_join_set.isSet(node.id);
    }

    // FIXME: remove buildFromJson and just do it all in init?
    pub fn init(alloc: std.mem.Allocator, env: Env) !Self {
        return Self{
            .env = env,
            .is_join_set = try std.DynamicBitSetUnmanaged.initEmpty(alloc, 0),
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.is_join_set.deinit(alloc);
        {
            var node_iter = self.nodes.map.iterator();
            while (node_iter.next()) |*node| {
                node.value_ptr.deinit(alloc);
            }
        }
        self.nodes.deinit(alloc);
        // do not delete env, we don't own it
    }

    const GetSingleExecFromEntryError = error{
        EntryNodeNoConnectedExecPins,
        ExecNodeMultiExecPin,
    };

    // FIXME: need to codify how this works, this gets the *first*, doesn't verify that it's singular
    pub fn getSingleExecFromEntry(in_entry: *const IndexedNode) GetSingleExecFromEntryError!GraphTypes.Output {
        var entry_exec: GetSingleExecFromEntryError!GraphTypes.Output = error.EntryNodeNoConnectedExecPins;
        for (in_entry.outputs, 0..) |output, i| {
            if (output == null)
                continue;
            const out_type = in_entry.desc.getOutputs()[i];
            if (out_type.kind == .primitive and out_type.kind.primitive == .exec) {
                if (entry_exec != error.EntryNodeNoConnectedExecPins) {
                    return error.ExecNodeMultiExecPin;
                }
                entry_exec = output.?;
            }
        }
        return entry_exec;
    }

    pub const BuildFromJsonDiagnostic = PopulateAndReturnEntryDiagnostic;

    pub const Diagnostic = BuildFromJsonDiagnostic;

    // HACK: remove force_node_id
    // TODO: return a pointer to the newly placed node?
    pub fn addNode(self: *@This(), alloc: std.mem.Allocator, kind: []const u8, is_entry: bool, force_node_id: ?NodeId, diag: ?*Diagnostic) !NodeId {
        const node_id: NodeId = force_node_id orelse @intCast(self.next_node_index);
        const putResult = try self.nodes.map.getOrPut(alloc, node_id);
        putResult.value_ptr.* = try self.env.makeNode(alloc, node_id, kind) orelse unreachable;
        const node = putResult.value_ptr;

        self.next_node_index += 1;
        errdefer self.next_node_index -= 1;

        if (putResult.found_existing) {
            if (diag) |d| d.* = .{ .DuplicateNode = node_id };
            return error.DuplicateNode;
        }

        errdefer std.debug.assert(self.nodes.map.swapRemove(node_id));

        if (is_entry) {
            if (self.entry_id != null) {
                if (diag) |d| d.* = .{ .MultipleEntries = node_id };
                return error.MultipleEntries;
            }
            self.entry_id = node_id;
        }

        // FIXME: a more sophisticated check for if it's a branch, including macro expansion
        const is_branch = std.mem.eql(u8, node.desc.name, "if");

        if (is_branch)
            self.branch_count += 1;

        errdefer if (is_branch) {
            self.branch_count -= 1;
        };

        return node_id;
    }

    pub fn addImport(self: *@This(), alloc: std.mem.Allocator, path: []const u8, bindings: []const ImportBinding) !void {
        const new_import = try self.imports.addOne(alloc);

        // TODO: it is tempting to create a comptime function that constructs sexp from zig tuples
        new_import.* = Sexp{
            .value = .{ .list = std.ArrayList(Sexp).init(alloc) },
        };

        (try new_import.*.value.list.addOne()).* = syms.import;
        (try new_import.*.value.list.addOne()).* = Sexp{ .value = .{ .symbol = path } };

        const imported_bindings = try new_import.*.value.list.addOne();
        imported_bindings.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };

        for (bindings) |binding| {
            const added = try imported_bindings.*.value.list.addOne();

            if (binding.alias) |alias| {
                (try added.*.value.list.addOne()).* = syms.as;
                (try added.*.value.list.addOne()).* = Sexp{ .value = .{ .symbol = binding.binding } };
                (try added.*.value.list.addOne()).* = Sexp{ .value = .{ .symbol = alias } };
            } else {
                added.* = Sexp{ .value = .{ .symbol = binding.binding } };
            }
        }
    }

    // TODO: rename to source/target
    /// end_subindex should be 0 if you don't know it
    pub fn addEdge(self: @This(), start_id: NodeId, start_index: u16, end_id: NodeId, end_index: u16, end_subindex: u16) !void {
        const start = self.nodes.map.getPtr(start_id) orelse return error.SourceNodeNotFound;
        const end = self.nodes.map.getPtr(end_id) orelse return error.TargetNodeNotFound;

        // TODO: some macros this might be allowable
        if (start_id == end_id) {
            // TODO: return diagnostic
            std.log.err("edges must be between nodes", .{});
            return error.SourceIndexInvalid;
        }

        if (start_index >= start.outputs.len) {
            // TODO: return diagnostic
            std.log.err("start_index {} not valid, only {} available inputs\n", .{ start_index, start.outputs.len });
            return error.SourceIndexInvalid;
        }

        if (end_index >= end.inputs.len) {
            // TODO: return diagnostic
            std.log.err("end_index {} not valid, only {} available inputs\n", .{ end_index, end.inputs.len });
            return error.TargetIndexInvalid;
        }

        start.outputs[start_index] = .{ .link = .{
            .target = end_id,
            .pin_index = end_index,
            .sub_index = end_subindex,
        } };

        end.inputs[end_index] = .{ .link = .{
            .target = start_id,
            .pin_index = start_index,
        } };
    }

    // NOTE: consider renaming to "setLiteralInput"
    pub fn addLiteralInput(self: @This(), node_id: NodeId, pin_index: u16, subpin_index: u16, value: Value) !void {
        const start = self.nodes.map.getPtr(node_id) orelse return error.SourceNodeNotFound;
        _ = subpin_index;

        if (pin_index >= start.inputs.len)
            return error.StartIndexInvalid;

        start.inputs[pin_index] = .{ .value = value };
    }

    // FIXME: emit move name to the graph
    /// NOTE: the outer module is a sexp list
    pub fn compile(self: *@This(), alloc: std.mem.Allocator, name: []const u8) !Sexp {
        try self.postPopulate(alloc);
        const body = try self.rootToSexp(alloc);
        std.debug.assert(body.value == .list);

        var module = Sexp{ .value = .{ .module = std.ArrayList(Sexp).init(alloc) } };
        try module.value.module.ensureTotalCapacityPrecise(2);
        const type_def = module.value.module.addOneAssumeCapacity();
        const func_def = module.value.module.addOneAssumeCapacity();

        {
            type_def.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) }, .comment = "comment!" };
            try type_def.value.list.ensureTotalCapacityPrecise(3);
            type_def.value.list.addOneAssumeCapacity().* = syms.typeof;
            const param_bindings = type_def.value.list.addOneAssumeCapacity();
            const result_type = type_def.value.list.addOneAssumeCapacity();

            param_bindings.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try param_bindings.value.list.ensureTotalCapacityPrecise(1 + self.params.items.len);
            // FIXME: dupe this?
            param_bindings.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = name } };
            for (self.params.items) |param| {
                param_bindings.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = param.type_.name } };
            }

            // FIXME: generate type from return node, anonymous struct maybe?
            result_type.* = primitive_type_syms.i32;
        }

        {
            func_def.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try func_def.value.list.ensureTotalCapacityPrecise(3);
            func_def.value.list.addOneAssumeCapacity().* = syms.define;
            const func_bindings = func_def.value.list.addOneAssumeCapacity();
            const body_begin = func_def.value.list.addOneAssumeCapacity();

            body_begin.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            // 1 for "begin", then local defs, then 1 for body
            try body_begin.value.list.ensureTotalCapacityPrecise(1 + self.locals.items.len + 1);
            body_begin.value.list.addOneAssumeCapacity().* = syms.begin;
            for (self.locals.items) |local| {
                const local_def = body_begin.value.list.addOneAssumeCapacity();
                local_def.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try local_def.value.list.ensureTotalCapacityPrecise(3);
                local_def.value.list.addOneAssumeCapacity().* = syms.define;
                local_def.value.list.addOneAssumeCapacity().* = Sexp{
                    .value = .{ .symbol = local.name },
                    .comment = local.comment,
                };
            }
            body_begin.value.list.addOneAssumeCapacity().* = body;

            // FIXME: also emit imports and definitions!
            func_bindings.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try func_bindings.value.list.ensureTotalCapacityPrecise(1 + self.params.items.len);
            // FIXME: dupe this?
            func_bindings.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = name } };
            for (self.params.items) |param| {
                func_bindings.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = param.name } };
            }
        }

        return module;
    }

    // FIXME: this should return a separate object
    pub fn buildFromJson(
        self: *Self,
        alloc: std.mem.Allocator,
        json_graph: GraphDoc,
        diagnostic: ?*BuildFromJsonDiagnostic,
    ) !Sexp {
        const entry_node = try self.populateFromJsonAndReturnEntry(alloc, json_graph, diagnostic);
        self.entry_id = entry_node.id;
        try self.link(alloc, json_graph);
        return self.rootToSexp(alloc);
    }

    // TODO: make errors stable somehow
    const PopulateAndReturnEntryDiagnostic = union(enum(u16)) {
        None = 0,
        DuplicateNode: i64,
        MultipleEntries: i64,
        UnknownNodeType: []const u8,

        const Code = error{
            DuplicateNode,
            MultipleEntries,
            UnknownNodeType,
        };

        pub fn code(self: @This()) Code {
            return switch (self) {
                .None => unreachable,
                .DuplicateNode => Code.DuplicateNode,
                .MultipleEntries => Code.MultipleEntries,
                .UnknownNodeType => Code.UnknownNodeType,
            };
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
                .None => _ = try writer.write("Not an error"),
                .DuplicateNode => |v| try writer.print("Duplicate node found. First duplicate id={}", .{v}),
                .MultipleEntries => |v| try writer.print("Multiple entries found. Second entry id={}", .{v}),
                .UnknownNodeType => |v| try writer.print("Unknown node type '{s}'", .{v}),
            }
        }
    };

    fn populateFromJsonAndReturnEntry(
        self: *Self,
        alloc: std.mem.Allocator,
        json_graph: GraphDoc,
        diagnostic: ?*PopulateAndReturnEntryDiagnostic,
    ) !*const IndexedNode {
        var ignored_diagnostic: PopulateAndReturnEntryDiagnostic = undefined;
        const out_diagnostic = diagnostic orelse &ignored_diagnostic;

        // FIXME: this belongs in buildFromJson...
        errdefer self.nodes.map.clearAndFree(alloc);

        var json_nodes_iter = json_graph.nodes.map.iterator();
        while (json_nodes_iter.next()) |node_entry| {
            const json_node_id = node_entry.key_ptr.*;
            // FIXME: accidental copy?
            const json_node = node_entry.value_ptr.*;

            _ = try self.addNode(alloc, json_node.type, json_node.data.isEntry, json_node_id, out_diagnostic);
        }

        const entry_id = self.entry_id orelse return error.GraphHasNoEntry;
        const entry_node = self.nodes.map.getPtr(entry_id) orelse unreachable;

        try self.postPopulate(alloc);

        return entry_node;
    }

    // TODO: rename to like analyze?
    fn postPopulate(self: *@This(), alloc: std.mem.Allocator) !void {
        try self.branch_joiner_map.ensureTotalCapacity(alloc, self.branch_count);
        try self.is_join_set.resize(alloc, self.nodes.map.count(), false);
    }

    pub fn link(self: @This(), alloc: std.mem.Allocator, graph_json: GraphDoc) !void {
        var nodes_iter = self.nodes.map.iterator();
        var json_nodes_iter = graph_json.nodes.map.iterator();
        std.debug.assert(nodes_iter.len == json_nodes_iter.len);

        while (nodes_iter.next()) |node_entry| {
            const node = node_entry.value_ptr;

            const json_node_entry = json_nodes_iter.next() orelse unreachable;
            const json_node = json_node_entry.value_ptr;

            try self.linkNode(alloc, json_node.*, node);
        }
    }

    /// link with other empty nodes in a graph
    pub fn linkNode(self: @This(), alloc: std.mem.Allocator, json_node: JsonNode, node: *IndexedNode) !void {
        _ = self;
        // FIXME: this leaks the already existing inputs, must free those first!
        node.inputs = try alloc.alloc(GraphTypes.Input, json_node.inputs.len);
        errdefer alloc.free(node.inputs);

        for (node.inputs, json_node.inputs) |*input, maybe_json_input| {
            input.* = switch (maybe_json_input orelse JsonNodeInput{ .value = .null }) {
                .handle => |h| .{ .link = .{
                    .target = h.nodeId,
                    .pin_index = h.handleIndex,
                } },
                .value => |v| .{ .value = v },
            };
        }

        node.outputs = try alloc.alloc(?GraphTypes.Output, json_node.outputs.len);
        errdefer alloc.free(node.outputs);

        for (node.outputs, json_node.outputs) |*output, maybe_json_output| {
            output.* = if (maybe_json_output) |json_output| .{ .link = .{
                .target = json_output.nodeId,
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

    // FIXME: stack-space-bound
    // To find the join of a branch, find all reachable end nodes
    // if there is only 1, it joins.
    // How to deal with inner branches: - If we encounter a branch within a branch, solve the inner branch first.
    // - If it doesn't join, neither does the super branch
    // - But if it does, that doesn't help us find the outer join node

    /// each branch will may have 1 (or 0) join node where the control flow for that branch converges
    /// first traverse all nodes getting for each its single end (or null if multiple), and its tree size
    pub fn analyzeNodes(self: *@This(), alloc: std.mem.Allocator) !void {
        errdefer self.branch_joiner_map.clearAndFree(alloc);
        errdefer self.is_join_set.deinit(alloc);

        var analysis_ctx: AnalysisCtx = .{};
        defer analysis_ctx.deinit(alloc);

        try analysis_ctx.node_data.resize(alloc, self.nodes.map.count());

        // initialize with empty data
        var slices = analysis_ctx.node_data.slice();
        @memset(slices.items(.visited)[0..analysis_ctx.node_data.len], 0);

        var node_iter = self.nodes.map.iterator();
        while (node_iter.next()) |node| {
            // inlined analyzeNode precondition because not sure with recursion compiler can figure it out
            if (analysis_ctx.node_data.items(.visited)[node.key_ptr.*] == 1)
                continue;

            try self.analyzeNode(node.value_ptr, &analysis_ctx);
        }
    }

    fn analyzeNode(
        self: *const @This(),
        node: *const IndexedNode,
        analysis_ctx: *AnalysisCtx,
    ) !void {
        if (analysis_ctx.node_data.items(.visited)[node.id] == 1)
            return;

        analysis_ctx.node_data.items(.visited)[node.id] = 1;

        const is_branch = std.mem.eql(u8, node.desc.name, "if");

        if (is_branch)
            _ = try self.analyzeBranch(node, analysis_ctx);
    }

    fn analyzeBranch(
        self: @This(),
        branch: *const IndexedNode,
        analysis_ctx: *AnalysisCtx,
    ) !?*const IndexedNode {
        if (analysis_ctx.node_data.items(.visited)[branch.id] == 1) {
            const prev_result = self.branch_joiner_map.get(branch);
            return .{ .value = prev_result };
        }

        analysis_ctx.node_data.items(.visited)[branch.id] = 1;

        const result = try self.doAnalyzeBranch(branch, analysis_ctx);

        try self.branch_joiner_map.put(result);
        self.is_join_set.set(result.id, true);

        return result;
    }

    // FIXME: handle macros, switches, etc
    // FIXME: prove the following, write down somewhere
    // NOTE: all multi-exec-input nodes necessarily are macros that just expand to single-exec-input nodes
    /// @returns the joining node for the branch, or null if it doesn't join
    fn doAnalyzeBranch(
        self: @This(),
        alloc: std.mem.Allocator,
        branch: *const IndexedNode,
        analysis_ctx: *AnalysisCtx,
    ) !?*const IndexedNode {
        if (analysis_ctx.node_data.items(.visited)[branch.index]) {
            const prev_result = self.branch_joiner_map.get(branch.index);
            return .{ .value = prev_result };
        }

        analysis_ctx.node_data.items(.visited)[branch.index] = 1;

        var collapsed_node_layer = std.AutoArrayHashMapUnmanaged(*const IndexedNode, {});
        try collapsed_node_layer.put(branch);
        defer collapsed_node_layer.deinit(alloc);

        while (true) {
            var new_collapsed_node_layer = std.AutoArrayHashMapUnmanaged(*const IndexedNode, {});

            for (collapsed_node_layer.items()) |collapsed_node| {
                const is_branch = std.mem.eql(u8, collapsed_node.desc.name, "if");

                if (is_branch) {
                    const joiner = try self.analyzeBranch(collapsed_node, analysis_ctx);
                    try new_collapsed_node_layer.put(joiner);
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

            collapsed_node_layer.clearAndFree(alloc);
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

        pub const Block = std.ArrayList(Sexp);

        const Context = struct {
            node_data: std.MultiArrayList(NodeData) = .{},
            block: Block,

            pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
                self.node_data.deinit(a);
                self.block.deinit();
            }
        };

        pub fn toSexp(self: @This(), alloc: std.mem.Allocator, node_id: NodeId) !Sexp {
            var ctx = Context{
                .block = Block.init(alloc),
            };
            errdefer ctx.deinit(alloc);
            try ctx.node_data.resize(alloc, self.graph.nodes.map.count());
            try self.onNode(alloc, node_id, &ctx);
            return Sexp{ .value = .{ .list = ctx.block } };
        }

        const Error = error{
            CyclesNotSupported,
            OutOfMemory,
        };

        pub fn onNode(self: @This(), alloc: std.mem.Allocator, node_id: NodeId, context: *Context) Error!void {
            // FIXME: not handled
            if (context.node_data.items(.visited)[node_id] == 1)
                return Error.CyclesNotSupported;

            const node = self.graph.nodes.map.getPtr(node_id) orelse std.debug.panic("onNode: couldn't find node by id={}", .{node_id});

            context.node_data.items(.visited)[node_id] = 1;

            return if (node.desc.isSimpleBranch())
                @call(debug_tail_call, onBranchNode, .{ self, alloc, node, context })
            else
                @call(debug_tail_call, onFunctionCallNode, .{ self, alloc, node, context });
        }

        // FIXME: refactor to find joins during this?
        pub fn onBranchNode(self: @This(), alloc: std.mem.Allocator, node: *const IndexedNode, context: *Context) !void {
            std.debug.assert(node.desc.isSimpleBranch());

            var consequence_sexp: Sexp = undefined;
            var alternative_sexp: Sexp = undefined;

            if (node.outputs[0]) |consequence| {
                var consequence_ctx = Context{
                    .node_data = context.node_data,
                    .block = Block.init(alloc),
                };
                // FIXME: only add `begin` if it's multiple expressions
                (try consequence_ctx.block.addOne()).* = syms.begin;
                try self.onNode(alloc, consequence.link.target, &consequence_ctx);
                consequence_sexp = Sexp{ .value = .{ .list = consequence_ctx.block } };
            }

            if (node.outputs[1]) |alternative| {
                var alternative_ctx = Context{
                    .node_data = context.node_data,
                    .block = Block.init(alloc),
                };
                // FIXME: only add `begin` if it's multiple expressions
                (try alternative_ctx.block.addOne()).* = syms.begin;
                try self.onNode(alloc, alternative.link.target, &alternative_ctx);
                alternative_sexp = Sexp{ .value = .{ .list = alternative_ctx.block } };
            }

            var branch_sexp = try context.block.addOne();
            errdefer branch_sexp.deinit(alloc);

            branch_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };

            // (if
            (try branch_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = node.desc.name } };

            // condition
            const condition_sexp = try self.nodeInputTreeToSexp(alloc, node.inputs[1]);
            (try branch_sexp.value.list.addOne()).* = condition_sexp;
            // consequence
            (try branch_sexp.value.list.addOne()).* = consequence_sexp;
            // alternative
            (try branch_sexp.value.list.addOne()).* = alternative_sexp;

            // FIXME: remove this double hash map fetch
            if (self.graph.branch_joiner_map.get(node)) |join| {
                return @call(debug_tail_call, onNode, .{ self, alloc, join.id, context });
            }
        }

        pub fn onFunctionCallNode(self: @This(), alloc: std.mem.Allocator, node: *const IndexedNode, context: *Context) !void {
            if (self.graph.isJoin(node))
                return;

            const special_type: enum { none, getter, setter } = if (std.mem.startsWith(u8, node.desc.name, "#"))
                if (std.mem.startsWith(u8, node.desc.name, "#GET#")) .getter else .setter
            else
                .none;

            const name =
                if (special_type != .none)
                node.desc.name["#GET#".len..]
            else
                node.desc.name;

            var call_sexp = try context.block.addOne();

            // FIXME: this must be unified with nodeInputTreeToSexp!
            call_sexp.* =
                if (special_type == .getter)
                Sexp{ .value = .{ .symbol = name } }
            else
                Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };

            if (special_type != .getter) {
                (try call_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = name } };

                for (node.inputs[1..]) |input| {
                    const input_tree = try self.nodeInputTreeToSexp(alloc, input);
                    (try call_sexp.value.list.addOne()).* = input_tree;
                }
            }

            if (node.outputs[0]) |next| {
                return @call(debug_tail_call, onNode, .{ self, alloc, next.link.target, context });
            }
        }

        fn nodeInputTreeToSexp(self: @This(), alloc: std.mem.Allocator, in_link: GraphTypes.Input) !Sexp {
            const sexp = switch (in_link) {
                .link => |v| _: {
                    const node = self.graph.nodes.map.getPtr(v.target) orelse std.debug.panic("couldn't find link target id={}", .{v.target});

                    // TODO: should have a comptime sexp parsing utility, or otherwise terser syntax...
                    const special_type: enum { none, getter, setter } = if (std.mem.startsWith(u8, node.desc.name, "#"))
                        if (std.mem.startsWith(u8, node.desc.name, "#GET#")) .getter else .setter
                    else
                        .none;

                    const name =
                        if (special_type != .none)
                        node.desc.name["#GET#".len..]
                    else
                        node.desc.name;

                    if (special_type == .getter)
                        break :_ Sexp{ .value = .{ .symbol = name } };

                    var result = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };

                    try result.value.list.ensureTotalCapacityPrecise(node.inputs.len + 1);

                    (try result.value.list.addOne()).* = Sexp{ .value = .{ .symbol = name } };

                    for (node.inputs) |input| {
                        (try result.value.list.addOne()).* = try self.nodeInputTreeToSexp(alloc, input);
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

    fn rootToSexp(self: *@This(), alloc: std.mem.Allocator) !Sexp {
        return if (self.entry()) |entry_node|
            if (entry_node.outputs[0]) |first_node|
                try (ToSexp{ .graph = self }).toSexp(alloc, first_node.link.target)
            else
                Sexp{ .value = .void }
        else
            error.NoEntryOrNotYetSet;
    }
};

// TODO: rework to use errors explicitly
const GraphToSourceErr = union(enum(u16)) {
    None = 0,
    // TODO: remove
    OutOfMemory: void = @intFromError(error.OutOfMemory),
    // TODO: remove
    IoErr: anyerror,

    Compile: GraphBuilder.BuildFromJsonDiagnostic,
    Read: json.Diagnostics,

    const Code = error{
        IoErr,
        OutOfMemory,
    } || GraphBuilder.BuildFromJsonDiagnostic.Code || json.Error;

    pub fn from(err: error{OutOfMemory}) GraphToSourceErr {
        return switch (err) {
            error.OutOfMemory => GraphToSourceErr{ .OutOfMemory = {} },
        };
    }

    pub fn code(self: @This()) Code {
        return switch (self) {
            .None => unreachable,
            .OutOfMemory => Code.OutOfMemory,
            .IoErr => Code.IoErr,
            .Compile => |v| v.code(), // FIXME: need Code to merge with errors from
            .Read => @panic("not supported yet"),
        };
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
            .None => _ = try writer.write("NotAnError"),
            .Compile => |v| try writer.print("Compile error: {}", .{v}),
            .Read => |v| try writer.print(
                \\error in JSON {}:{}, (byte={})
            , .{ v.getLine(), v.getColumn(), v.getByteOffset() }),
        }
    }
};

pub const GraphToSourceDiagnostic = GraphToSourceErr;

// TODO: use cap'n proto instead of JSON

/// caller must free result with the given allocator
pub fn graphToSource(a: std.mem.Allocator, graph_json: []const u8, diagnostic: ?*GraphToSourceDiagnostic) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const env = try Env.initDefault(arena_alloc);

    var json_diagnostics = json.Diagnostics{};
    var graph_json_reader = json.Scanner.initCompleteInput(arena_alloc, graph_json);
    graph_json_reader.enableDiagnostics(&json_diagnostics);
    const graph = json.parseFromTokenSourceLeaky(GraphDoc, arena_alloc, &graph_json_reader, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        if (diagnostic) |d| d.* = GraphToSourceDiagnostic{ .Read = json_diagnostics };
        return e;
    };

    var page_writer = try PageWriter.init(arena_alloc);
    defer page_writer.deinit();

    var import_exprs = std.ArrayList(Sexp).init(arena_alloc);
    defer import_exprs.deinit();
    try import_exprs.ensureTotalCapacityPrecise(graph.imports.map.count());

    var builder = try GraphBuilder.init(arena_alloc, env);
    defer builder.deinit(arena_alloc);

    // TODO: refactor blocks into functions
    {
        {
            // TODO: errdefer delete all added imports
            var imports_iter = graph.imports.map.iterator();
            while (imports_iter.next()) |json_import_entry| {
                const json_import_name = json_import_entry.key_ptr.*;
                const json_import_bindings = json_import_entry.value_ptr.*;

                const bindings = try arena_alloc.alloc(ImportBinding, json_import_bindings.len);
                defer arena_alloc.free(bindings);

                for (json_import_bindings, bindings) |json_imported_binding, *binding| {
                    const ref = json_imported_binding.ref;
                    binding.* = .{
                        .binding = ref,
                        .alias = json_imported_binding.alias,
                    };
                }

                try builder.addImport(arena_alloc, json_import_name, bindings);
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

    const sexp = try builder.buildFromJson(
        arena_alloc,
        graph,
        if (diagnostic) |d| _: {
            d.* = .{ .Compile = .None };
            break :_ &d.Compile;
        } else null,
    );

    _ = try sexp.write(page_writer.writer());
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

    var diagnostic: GraphToSourceDiagnostic = undefined;
    const result = graphToSource(alloc, graph_json.buffer, &diagnostic);
    if (result) |compiled_source| {
        try testing.expectEqualStrings(source.buffer, compiled_source);
        alloc.free(compiled_source);
    } else |err| {
        debug_print("\nDIAGNOSTIC ({}):\n{}\n", .{ err, diagnostic });
        return error.FailTest;
    }
}

test "small local built graph" {
    const a = testing.allocator;

    var env = try Env.initDefault(a);
    defer env.deinit(a);

    var diagnostic: GraphBuilder.Diagnostic = .None;
    errdefer std.debug.print("DIAGNOSTIC:\n{}\n", .{diagnostic});
    var builder = GraphBuilder.init(a, env) catch |e| {
        std.debug.print("\nERROR: {}\n", .{e});
        return e;
    };
    defer builder.deinit(a);

    const entry_index = try builder.addNode(a, "CustomTickEntry", true, null, &diagnostic);
    const plus_index = try builder.addNode(a, "+", false, null, &diagnostic);
    const actor_loc_index = try builder.addNode(a, "#GET#actor-location", false, null, &diagnostic);
    const set_index = try builder.addNode(a, "set!", false, null, &diagnostic);

    try builder.addEdge(actor_loc_index, 0, plus_index, 0, 0);
    try builder.addLiteralInput(plus_index, 1, 0, .{ .number = 4.0 });
    try builder.addEdge(entry_index, 0, set_index, 0, 0);
    try builder.addLiteralInput(set_index, 1, 0, .{ .symbol = "x" });
    try builder.addEdge(plus_index, 0, set_index, 2, 0);

    const sexp = builder.compile(a) catch |e| {
        std.debug.print("\ncompile error: {}\n", .{e});
        return e;
    };
    defer sexp.deinit(a);

    var text = std.ArrayList(u8).init(a);
    defer text.deinit();
    _ = try sexp.write(text.writer());

    try testing.expectEqualStrings(
        \\(set! x
        \\      (+ actor-location
        \\         4))
        // TODO: print floating point explicitly
    , text.items);
}
