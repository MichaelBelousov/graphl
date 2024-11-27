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

// FIXME: better name
const helpers = @import("./nodes/builtin.zig");
const Env = @import("./nodes/builtin.zig").Env;
const Type = @import("./nodes/builtin.zig").Type;
const Value = @import("./nodes/builtin.zig").Value;
const NodeDesc = @import("./nodes/builtin.zig").NodeDesc;
const BasicMutNodeDesc = @import("./nodes/builtin.zig").BasicMutNodeDesc;
const Pin = @import("./nodes/builtin.zig").Pin;

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

pub const Binding = helpers.Binding;

/// all APIs taking an allocator must use the same allocator
pub const GraphBuilder = struct {
    env: *Env,
    // FIXME: don't these get invalidated since it's backed by an array?
    // FIXME: does this need to be in topological order? Is that advantageous?
    /// map of json node ids to its real node,
    nodes: JsonIntArrayHashMap(NodeId, IndexedNode, 10) = .{},

    branch_joiner_map: std.AutoHashMapUnmanaged(NodeId, NodeId) = .{},
    is_join_set: std.DynamicBitSetUnmanaged,

    entry_id: ?NodeId = null,

    branch_count: u32 = 0,
    // NEXT: setting this to 1 instead of 0 broke shit
    next_node_index: usize = 0, // 0 is reserved for entry

    // FIXME: who owns these?
    imports: std.ArrayListUnmanaged(Sexp) = .{},
    locals: std.ArrayListUnmanaged(Binding) = .{},

    // FIXME: consolidate input nodes with types and structs
    result_node_basic_desc: *BasicMutNodeDesc,
    result_node: *const NodeDesc,
    entry_node_basic_desc: *BasicMutNodeDesc,
    // FIXME: rename to NodeDesc
    entry_node: *const NodeDesc,

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
    pub fn init(alloc: std.mem.Allocator, env: *Env) !Self {
        const entry_node_basic_desc = _: {
            const inputs = try alloc.alloc(Pin, 0);
            const outputs = try alloc.alloc(Pin, 1);
            outputs[0] = Pin{ .name = "start", .kind = .{ .primitive = .exec } };

            const result = try alloc.create(BasicMutNodeDesc);

            result.* = .{
                .name = "enter",
                .hidden = true,
                .inputs = inputs,
                .outputs = outputs,
            };

            break :_ result;
        };

        // FIXME: this breaks without layered envs!
        const entry_node = try env.addNode(alloc, helpers.basicMutableNode(entry_node_basic_desc));

        const result_node_basic_desc = _: {
            const inputs = try alloc.alloc(Pin, 2);
            inputs[0] = Pin{ .name = "exit", .kind = .{ .primitive = .exec } };
            inputs[1] = Pin{ .name = "result", .kind = .{ .primitive = .{ .value = helpers.primitive_types.i32_ } } };

            const outputs = try alloc.alloc(Pin, 0);

            const result = try alloc.create(BasicMutNodeDesc);

            result.* = .{
                .name = "return",
                .hidden = false,
                .inputs = inputs,
                .outputs = outputs,
            };

            break :_ result;
        };

        const result_node = try env.addNode(alloc, helpers.basicMutableNode(result_node_basic_desc));

        var self = Self{
            .env = env,
            .is_join_set = try std.DynamicBitSetUnmanaged.initEmpty(alloc, 0),
            // initialized below
            .result_node = result_node,
            .result_node_basic_desc = result_node_basic_desc,
            .entry_node = entry_node,
            .entry_node_basic_desc = entry_node_basic_desc,
        };

        const entry_id = self.addNode(alloc, self.entry_node_basic_desc.name, true, 0, null) catch unreachable;
        _ = entry_id;
        //const return_id = self.addNode(alloc, self.result_node_basic_desc.name, false, null, null) catch unreachable;
        //self.addEdge(entry_id, 0, return_id, 0, 0) catch unreachable;

        return self;
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        std.debug.assert(self.env._nodes.remove(self.entry_node_basic_desc.name));
        std.debug.assert(self.env._nodes.remove(self.result_node_basic_desc.name));
        alloc.free(self.entry_node_basic_desc.outputs);
        alloc.free(self.entry_node_basic_desc.inputs);
        alloc.destroy(self.entry_node_basic_desc);
        alloc.free(self.result_node_basic_desc.outputs);
        alloc.free(self.result_node_basic_desc.inputs);
        alloc.destroy(self.result_node_basic_desc);

        self.is_join_set.deinit(alloc);
        {
            var node_iter = self.nodes.map.iterator();
            while (node_iter.next()) |*node| {
                node.value_ptr.deinit(alloc);
            }
        }
        self.nodes.deinit(alloc);
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
            const out_type = in_entry.desc().getOutputs()[i];
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
    pub fn addNode(self: *@This(), alloc: std.mem.Allocator, kind: []const u8, is_entry: bool, force_node_id: ?NodeId, diag: ?*Diagnostic) !NodeId {
        const node_id: NodeId = force_node_id orelse @intCast(self.next_node_index);
        const putResult = try self.nodes.map.getOrPut(alloc, node_id);
        putResult.value_ptr.* = try self.env.spawnNodeOfKind(alloc, node_id, kind) orelse {
            std.log.err("attempted to spawn unknown node: '{s}'", .{kind});
            unreachable;
        };
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
        // FIXME: gross comparison
        const is_branch = node.desc() == &helpers.builtin_nodes.@"if";

        if (is_branch) {
            self.branch_count += 1;
        }

        errdefer if (is_branch) {
            self.branch_count -= 1;
        };

        return node_id;
    }

    /// returns true if the node existed (and therefore was removed)
    pub fn removeNode(self: *@This(), id: NodeId) !bool {
        if (id == self.entry_id) return error.CantRemoveEntry;

        const node = self.nodes.map.getPtr(id) orelse return false;

        const is_branch = node.desc() == &helpers.builtin_nodes.@"if";
        if (is_branch) {
            self.branch_count -= 1;
        }
        errdefer if (is_branch) {
            self.branch_count += 1;
        };

        return self.nodes.map.swapRemove(id);
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

    pub fn removeEdge(self: @This(), start_id: NodeId, start_index: u16, end_id: NodeId, end_index: u16, end_subindex: u16) !void {
        _ = end_subindex;
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

        start.outputs[start_index] = null;

        // FIXME: should have a function to choose the default for a disconnected pin
        end.inputs[end_index] = .{ .value = .{ .int = 0 } };
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
        try self.branch_joiner_map.ensureTotalCapacity(alloc, self.branch_count);
        try self.is_join_set.resize(alloc, self.nodes.map.count(), false);

        // FIXME: this causes a crash in non-debug builds
        //var analysis_arena = std.heap.ArenaAllocator.init(alloc);
        //try self.analyzeNodes(alloc);
        //analysis_arena.deinit();

        var body = try self.rootToSexp(alloc);
        // FIXME: doesn't this invalidate the moved slice below? e.g. this only works cuz there are no owned strings?
        defer body.deinit(alloc);
        std.debug.assert(body.value == .list);

        var module = Sexp{ .value = .{ .module = std.ArrayList(Sexp).init(alloc) } };
        try module.value.module.ensureTotalCapacityPrecise(2);
        const type_def = module.value.module.addOneAssumeCapacity();
        const func_def = module.value.module.addOneAssumeCapacity();

        const params = self.entry_node_basic_desc.outputs[1..];

        {
            type_def.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) }, .comment = "comment!" };
            try type_def.value.list.ensureTotalCapacityPrecise(3);
            type_def.value.list.addOneAssumeCapacity().* = syms.typeof;
            const param_bindings = type_def.value.list.addOneAssumeCapacity();
            const result_type = type_def.value.list.addOneAssumeCapacity();

            param_bindings.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try param_bindings.value.list.ensureTotalCapacityPrecise(1 + params.len);
            // FIXME: dupe this?
            param_bindings.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = name } };
            for (params) |param| {
                std.debug.assert(param.asPrimitivePin() == .value);
                param_bindings.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = param.asPrimitivePin().value.name } };
            }

            std.debug.assert(self.result_node_basic_desc.inputs.len >= 2);
            std.debug.assert(self.result_node_basic_desc.inputs[1].kind == .primitive);
            std.debug.assert(self.result_node_basic_desc.inputs[1].kind.primitive == .value);
            // FIXME: share symbols for primitives!
            result_type.* = Sexp{ .value = .{ .symbol = self.result_node_basic_desc.inputs[1].kind.primitive.value.name } };
        }

        {
            func_def.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try func_def.value.list.ensureTotalCapacityPrecise(3);
            func_def.value.list.addOneAssumeCapacity().* = syms.define;
            const func_bindings = func_def.value.list.addOneAssumeCapacity();
            const body_begin = func_def.value.list.addOneAssumeCapacity();

            body_begin.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            // 1 for "begin", then local defs, then 1 for body
            try body_begin.value.list.ensureTotalCapacityPrecise(1 + 2 * self.locals.items.len + body.value.list.items.len + 1);
            body_begin.value.list.addOneAssumeCapacity().* = syms.begin;
            for (self.locals.items) |local| {
                const local_type = body_begin.value.list.addOneAssumeCapacity();
                local_type.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try local_type.value.list.ensureTotalCapacityPrecise(3);
                local_type.value.list.addOneAssumeCapacity().* = syms.typeof;
                local_type.value.list.addOneAssumeCapacity().* = Sexp{
                    .value = .{ .symbol = local.name },
                    .comment = local.comment,
                };
                local_type.value.list.addOneAssumeCapacity().* = Sexp{
                    .value = .{ .symbol = local.type_.name },
                    .comment = local.comment,
                };

                const local_def = body_begin.value.list.addOneAssumeCapacity();
                local_def.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try local_def.value.list.ensureTotalCapacityPrecise(if (local.default != null) 3 else 2);
                local_def.value.list.addOneAssumeCapacity().* = syms.define;
                local_def.value.list.addOneAssumeCapacity().* = Sexp{
                    .value = .{ .symbol = local.name },
                    .comment = local.comment,
                };
                if (local.default) |default|
                    local_def.value.list.addOneAssumeCapacity().* = default;
            }
            body_begin.value.list.appendSliceAssumeCapacity(body.value.list.items);
            body.value.list.clearAndFree();

            // FIXME: also emit imports and definitions!
            func_bindings.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try func_bindings.value.list.ensureTotalCapacityPrecise(1 + params.len);
            // FIXME: dupe this?
            func_bindings.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = name } };
            for (params) |param| {
                func_bindings.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = param.name } };
            }
        }

        return module;
    }

    // // FIXME: this should return a separate object
    // pub fn buildFromJson(
    //     self: *Self,
    //     alloc: std.mem.Allocator,
    //     json_graph: GraphDoc,
    //     diagnostic: ?*BuildFromJsonDiagnostic,
    // ) !Sexp {
    //     const entry_node = try self.populateFromJsonAndReturnEntry(alloc, json_graph, diagnostic);
    //     self.entry_id = entry_node.id;
    //     try self.link(alloc, json_graph);
    //     return self.rootToSexp(alloc);
    // }

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

    const NodeAnalysisErr = error{OutOfMemory};

    // FIXME: stack-space-bound
    // To find the join of a branch, find all reachable end nodes
    // if there is only 1, it joins.
    // How to deal with inner branches: - If we encounter a branch within a branch, solve the inner branch first.
    // - If it doesn't join, neither does the super branch
    // - But if it does, that doesn't help us find the outer join node

    /// each branch will may have 1 (or 0) join node where the control flow for that branch converges
    /// first traverse all nodes getting for each its single end (or null if multiple), and its tree size
    pub fn analyzeNodes(self: *@This(), alloc: std.mem.Allocator) NodeAnalysisErr!void {
        errdefer self.branch_joiner_map.clearAndFree(alloc);
        errdefer self.is_join_set.unsetAll();

        var analysis_ctx: AnalysisCtx = .{};
        defer analysis_ctx.deinit(alloc);

        try analysis_ctx.node_data.resize(alloc, self.nodes.map.count());

        // initialize with empty data
        var slices = analysis_ctx.node_data.slice();
        @memset(slices.items(.visited)[0..analysis_ctx.node_data.len], 0);

        // FIXME: use value iterator
        var node_iter = self.nodes.map.iterator();
        while (node_iter.next()) |node| {
            // inlined analyzeNode precondition because not sure with recursion compiler can figure it out
            if (analysis_ctx.node_data.items(.visited)[node.key_ptr.*] == 1)
                continue;

            try self.analyzeNode(alloc, node.value_ptr, &analysis_ctx);
        }
    }

    fn analyzeNode(
        self: *@This(),
        alloc: std.mem.Allocator,
        node: *const IndexedNode,
        analysis_ctx: *AnalysisCtx,
    ) NodeAnalysisErr!void {
        if (analysis_ctx.node_data.items(.visited)[node.id] == 1)
            return;

        analysis_ctx.node_data.items(.visited)[node.id] = 1;

        const is_branch = node.desc() == &helpers.builtin_nodes.@"if";

        if (is_branch)
            _ = try self.analyzeBranch(alloc, node, analysis_ctx);
    }

    fn analyzeBranch(
        self: *@This(),
        alloc: std.mem.Allocator,
        branch: *const IndexedNode,
        analysis_ctx: *AnalysisCtx,
    ) NodeAnalysisErr!?*const IndexedNode {
        if (analysis_ctx.node_data.items(.visited)[branch.id] == 1) {
            const prev_result_id = self.branch_joiner_map.get(branch.id);
            return self.nodes.map.getPtr(if (prev_result_id) |v| v else return null);
        }

        analysis_ctx.node_data.items(.visited)[branch.id] = 1;

        const result = try self.doAnalyzeBranch(alloc, branch, analysis_ctx);

        if (result) |joiner| {
            try self.branch_joiner_map.put(alloc, branch.id, joiner.id);
            self.is_join_set.set(joiner.id);
        }

        return result;
    }

    // FIXME: handle macros, switches, etc
    // FIXME: prove the following, write down somewhere
    // NOTE: all multi-exec-input nodes necessarily are macros that just expand to single-exec-input nodes
    /// @returns the joining node for the branch, or null if it doesn't join
    fn doAnalyzeBranch(
        self: *@This(),
        alloc: std.mem.Allocator,
        branch: *const IndexedNode,
        analysis_ctx: *AnalysisCtx,
    ) NodeAnalysisErr!?*const IndexedNode {
        if (analysis_ctx.node_data.items(.visited)[branch.id] == 1) {
            const prev_result_id = self.branch_joiner_map.get(branch.id);
            return self.nodes.map.getPtr(if (prev_result_id) |v| v else return null);
        }

        analysis_ctx.node_data.items(.visited)[branch.id] = 1;

        const NodeSet = std.AutoArrayHashMapUnmanaged(*const IndexedNode, void);
        var collapsed_node_layer = NodeSet{};
        try collapsed_node_layer.put(alloc, branch, {});
        defer collapsed_node_layer.deinit(alloc);

        // FIXME: cycles  aren't handled well, it's BFS so won't kill the algo
        // but might slow it down
        while (true) {
            var new_collapsed_node_layer = NodeSet{};

            for (collapsed_node_layer.keys()) |collapsed_node| {
                const is_branch = collapsed_node.desc() == &helpers.builtin_nodes.@"if";

                if (is_branch) {
                    const maybe_joiner = try self.analyzeBranch(alloc, collapsed_node, analysis_ctx);
                    if (maybe_joiner) |joiner| {
                        try new_collapsed_node_layer.put(alloc, joiner, {});
                    }
                } else {
                    for (collapsed_node.outputs, collapsed_node.desc().getOutputs()) |maybe_output, output_desc| {
                        if (!output_desc.isExec()) continue;
                        if (maybe_output == null) continue;
                        const output = maybe_output.?;
                        const target = self.nodes.map.getPtr(output.link.target) orelse unreachable;
                        try new_collapsed_node_layer.put(alloc, target, {});
                    }
                }
            }

            const new_layer_count = new_collapsed_node_layer.count();

            if (new_layer_count == 0)
                return null;
            if (new_layer_count == 1)
                return new_collapsed_node_layer.keys()[0]; // should always have at least 1

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
                for (self.block.items) |member| member.deinit(a);
                self.block.deinit();
            }
        };

        pub fn toSexp(self: @This(), alloc: std.mem.Allocator, node_id: NodeId) !Sexp {
            var ctx = Context{
                .block = Block.init(alloc),
            };
            defer ctx.deinit(alloc);
            try ctx.node_data.resize(alloc, self.graph.nodes.map.count());
            try self.onNode(alloc, node_id, &ctx);
            return Sexp{ .value = .{ .list = std.ArrayList(Sexp).fromOwnedSlice(alloc, try ctx.block.toOwnedSlice()) } };
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

            return if (node.desc().isSimpleBranch())
                @call(debug_tail_call, onBranchNode, .{ self, alloc, node, context })
            else
                @call(debug_tail_call, onFunctionCallNode, .{ self, alloc, node, context });
        }

        // FIXME: refactor to find joins during this?
        pub fn onBranchNode(self: @This(), alloc: std.mem.Allocator, node: *const IndexedNode, context: *Context) !void {
            std.debug.assert(node.desc().isSimpleBranch());

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
            (try branch_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = node.desc().name() } };

            // condition
            const condition_sexp = try self.nodeInputTreeToSexp(alloc, node.inputs[1]);
            (try branch_sexp.value.list.addOne()).* = condition_sexp;
            // consequence
            (try branch_sexp.value.list.addOne()).* = consequence_sexp;
            // alternative
            (try branch_sexp.value.list.addOne()).* = alternative_sexp;

            // FIXME: remove this double hash map fetch
            if (self.graph.branch_joiner_map.get(node.id)) |join| {
                return @call(debug_tail_call, onNode, .{ self, alloc, join, context });
            }
        }

        pub fn onFunctionCallNode(self: @This(), alloc: std.mem.Allocator, node: *const IndexedNode, context: *Context) !void {
            if (self.graph.isJoin(node))
                return;

            const special_type = node.kind;

            const name = node.desc().name();

            var call_sexp = try context.block.addOne();

            // FIXME: this must be unified with nodeInputTreeToSexp!
            call_sexp.* =
                if (special_type == .get)
                Sexp{ .value = .{ .symbol = name } }
            else
                Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };

            (try call_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = name } };

            // FIXME: doesn't work for variadics
            for (node.inputs, node.desc().getInputs()) |input, input_desc| {
                std.debug.assert(input_desc.kind == .primitive);
                switch (input_desc.kind.primitive) {
                    .exec => {},
                    .value => {
                        const input_tree = try self.nodeInputTreeToSexp(alloc, input);
                        (try call_sexp.value.list.addOne()).* = input_tree;
                    },
                }
            }

            for (node.outputs, node.desc().getOutputs()) |output, output_desc| {
                // FIXME: tail call where possible?
                //return @call(debug_tail_call, onNode, .{ self, alloc, node.outputs[0].?.link.target, context });
                if (output != null and output_desc.kind.primitive == .exec) {
                    try self.onNode(alloc, output.?.link.target, context);
                }
            }
        }

        fn nodeInputTreeToSexp(self: @This(), alloc: std.mem.Allocator, in_link: GraphTypes.Input) !Sexp {
            const sexp = switch (in_link) {
                .link => |v| _: {
                    // FIXME: is void really correct?
                    const target = if (v) |_v| _v.target else return Sexp{ .value = .void };
                    const node = self.graph.nodes.map.getPtr(target) orelse std.debug.panic("couldn't find link target id={}", .{target});

                    const special_type = node.kind;

                    const name = node.desc().name();

                    if (special_type == .get)
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
                    .int => |u| Sexp{ .value = .{ .int = u } },
                    .float => |u| Sexp{ .value = .{ .float = u } },
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
        if (self.entry_id == null) {
            return error.NoEntryOrNotYetSet;
        }

        std.debug.assert(self.entry().?.desc().getOutputs()[0].isExec());

        if (self.entry().?.outputs[0] == null)
            return Sexp{ .value = .void };

        const after_entry_id = self.entry().?.outputs[0].?.link.target;
        return (ToSexp{ .graph = self }).toSexp(alloc, after_entry_id);
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

// caller must free result with the given allocator
// pub fn graphToSource(a: std.mem.Allocator, graph_json: []const u8, diagnostic: ?*GraphToSourceDiagnostic) ![]const u8 {
//     var arena = std.heap.ArenaAllocator.init(a);
//     defer arena.deinit();
//     const arena_alloc = arena.allocator();

//     const env = try Env.initDefault(arena_alloc);

//     var json_diagnostics = json.Diagnostics{};
//     var graph_json_reader = json.Scanner.initCompleteInput(arena_alloc, graph_json);
//     graph_json_reader.enableDiagnostics(&json_diagnostics);
//     const graph = json.parseFromTokenSourceLeaky(GraphDoc, arena_alloc, &graph_json_reader, .{
//         .ignore_unknown_fields = true,
//     }) catch |e| {
//         if (diagnostic) |d| d.* = GraphToSourceDiagnostic{ .Read = json_diagnostics };
//         return e;
//     };

//     var page_writer = try PageWriter.init(arena_alloc);
//     defer page_writer.deinit();

//     var import_exprs = std.ArrayList(Sexp).init(arena_alloc);
//     defer import_exprs.deinit();
//     try import_exprs.ensureTotalCapacityPrecise(graph.imports.map.count());

//     var builder = try GraphBuilder.init(arena_alloc, env);
//     defer builder.deinit(arena_alloc);

//     // TODO: refactor blocks into functions
//     {
//         {
//             // TODO: errdefer delete all added imports
//             var imports_iter = graph.imports.map.iterator();
//             while (imports_iter.next()) |json_import_entry| {
//                 const json_import_name = json_import_entry.key_ptr.*;
//                 const json_import_bindings = json_import_entry.value_ptr.*;

//                 const bindings = try arena_alloc.alloc(ImportBinding, json_import_bindings.len);
//                 defer arena_alloc.free(bindings);

//                 for (json_import_bindings, bindings) |json_imported_binding, *binding| {
//                     const ref = json_imported_binding.ref;
//                     binding.* = .{
//                         .binding = ref,
//                         .alias = json_imported_binding.alias,
//                     };
//                 }

//                 try builder.addImport(arena_alloc, json_import_name, bindings);
//             }
//         }

//         for (import_exprs.items) |import| {
//             _ = import.write(page_writer.writer()) catch |e| return {
//                 if (diagnostic) |d| d.* = .{ .IoErr = e };
//                 return e;
//             };
//             _ = try page_writer.writer().write("\n");
//         }
//     }

//     const sexp = try builder.buildFromJson(
//         arena_alloc,
//         graph,
//         if (diagnostic) |d| _: {
//             d.* = .{ .Compile = .None };
//             break :_ &d.Compile;
//         } else null,
//     );

//     _ = try sexp.write(page_writer.writer());
//     _ = try page_writer.writer().write("\n");

//     // FIXME: provide API to free this
//     return page_writer.concat(global_alloc);
// }

test "big local built graph" {
    const a = testing.allocator;

    var env = try Env.initDefault(a);
    defer env.deinit(a);

    _ = try env.addNode(a, helpers.basicNode(&.{
        .name = "throw-confetti",
        .inputs = &.{
            helpers.Pin{ .name = "run", .kind = .{ .primitive = .exec } },
            helpers.Pin{ .name = "particle count", .kind = .{ .primitive = .{ .value = helpers.primitive_types.i32_ } } },
        },
        .outputs = &.{
            helpers.Pin{ .name = "", .kind = .{ .primitive = .exec } },
        },
    }));

    var diagnostic: GraphBuilder.Diagnostic = .None;
    errdefer std.debug.print("DIAGNOSTIC:\n{}\n", .{diagnostic});
    var graph = GraphBuilder.init(a, &env) catch |e| {
        std.debug.print("\nERROR: {}\n", .{e});
        return e;
    };
    defer graph.deinit(a);

    try graph.locals.append(a, .{
        .name = try a.dupe(u8, "x"),
        .type_ = helpers.primitive_types.i32_,
    });
    defer for (graph.locals.items) |l| a.free(l.name);

    const return_index = try graph.addNode(a, "return", true, null, null);
    const plus_index = try graph.addNode(a, "+", false, null, &diagnostic);
    const set_index = try graph.addNode(a, "set!", false, null, &diagnostic);
    const confetti_index = try graph.addNode(a, "throw-confetti", false, null, &diagnostic);
    const set2_index = try graph.addNode(a, "set!", false, null, &diagnostic);

    try graph.addLiteralInput(plus_index, 0, 0, .{ .float = 4.0 });
    try graph.addLiteralInput(plus_index, 1, 0, .{ .int = 8 });
    try graph.addLiteralInput(set_index, 1, 0, .{ .symbol = "x" });
    try graph.addLiteralInput(confetti_index, 1, 0, .{ .int = 100 });
    try graph.addLiteralInput(set2_index, 1, 0, .{ .symbol = "x" });
    try graph.addLiteralInput(set2_index, 2, 0, .{ .int = 10 });
    try graph.addEdge(set2_index, 0, confetti_index, 0, 0);
    try graph.addEdge(confetti_index, 0, set_index, 0, 0);
    try graph.addEdge(plus_index, 0, set_index, 2, 0);
    try graph.addEdge(set_index, 0, return_index, 0, 0);

    const sexp = graph.compile(a, "main") catch |e| {
        std.debug.print("\ncompile error: {}\n", .{e});
        return e;
    };
    defer sexp.deinit(a);

    var text = std.ArrayList(u8).init(a);
    defer text.deinit();
    _ = try sexp.write(text.writer());

    try testing.expectEqualStrings(
        \\(typeof (main)
        \\        i32)
        \\(define (main)
        \\        (begin (typeof x
        \\                       i32)
        \\               (define x)
        \\               (set! x
        \\                     10)
        \\               (throw-confetti 100)
        \\               (set! x
        \\                     (+ 4
        \\                        8))
        \\               (return 0)))
        // TODO: print floating point explicitly
    , text.items);
}

// test "small local built graph" {
//     const a = testing.allocator;

//     var env = try Env.initDefault(a);
//     defer env.deinit(a);

//     _ = try env.addNode(a, helpers.basicNode(&.{
//         .name = "throw-confetti",
//         .inputs = &.{
//             helpers.Pin{ .name = "run", .kind = .{ .primitive = .exec } },
//             helpers.Pin{ .name = "particle count", .kind = .{ .primitive = .{ .value = helpers.primitive_types.i32_ } } },
//         },
//         .outputs = &.{
//             helpers.Pin{ .name = "", .kind = .{ .primitive = .exec } },
//         },
//     }));

//     var diagnostic: GraphBuilder.Diagnostic = .None;
//     errdefer std.debug.print("DIAGNOSTIC:\n{}\n", .{diagnostic});
//     var graph = GraphBuilder.init(a, &env) catch |e| {
//         std.debug.print("\nERROR: {}\n", .{e});
//         return e;
//     };
//     defer graph.deinit(a);

//     const confetti_index = try graph.addNode(a, "throw-confetti", false, null, &diagnostic);
//     const confetti2_index = try graph.addNode(a, "throw-confetti", false, null, &diagnostic);
//     // FIXME:
//     const entry_index = 0;
//     const return_index = 1;

//     try graph.addLiteralInput(confetti_index, 1, 0, .{ .int = 100 });
//     try graph.addLiteralInput(confetti2_index, 1, 0, .{ .int = 200 });
//     try graph.addEdge(entry_index, 0, confetti_index, 0, 0);
//     try graph.addEdge(confetti_index, 0, confetti2_index, 0, 0);
//     try graph.addEdge(confetti2_index, 0, return_index, 0, 0);

//     const sexp = graph.compile(a, "main") catch |e| {
//         std.debug.print("\ncompile error: {}\n", .{e});
//         return e;
//     };
//     defer sexp.deinit(a);

//     var text = std.ArrayList(u8).init(a);
//     defer text.deinit();
//     _ = try sexp.write(text.writer());

//     try testing.expectEqualStrings(
//         \\(typeof (main)
//         \\        i32)
//         \\(define (main)
//         \\        (begin (throw-confetti 100)
//         \\               (throw-confetti 200)
//         \\               (return 0)))
//         // TODO: print floating point explicitly
//     , text.items);
// }

test "empty graph twice" {
    const a = testing.allocator;

    var env = try Env.initDefault(a);
    defer env.deinit(a);

    var graph = GraphBuilder.init(a, &env) catch |e| {
        std.debug.print("\nERROR: {}\n", .{e});
        return e;
    };
    defer graph.deinit(a);

    const first_sexp = graph.compile(a, "main") catch |e| {
        std.debug.print("\ncompile error: {}\n", .{e});
        return e;
    };
    first_sexp.deinit(a);

    const second_sexp = graph.compile(a, "main") catch |e| {
        std.debug.print("\ncompile error: {}\n", .{e});
        return e;
    };
    second_sexp.deinit(a);

    const third_sexp = graph.compile(a, "main") catch |e| {
        std.debug.print("\ncompile error: {}\n", .{e});
        return e;
    };
    defer third_sexp.deinit(a);

    var text = std.ArrayList(u8).init(a);
    defer text.deinit();
    _ = try third_sexp.write(text.writer());

    try testing.expectEqualStrings(
        \\(typeof (main)
        \\        i32)
        \\(define (main)
        \\        (begin (return 0)))
        // TODO: print floating point explicitly
    , text.items);

    const compiler = @import("./compiler-wat.zig");
    var compile_diag = compiler.Diagnostic.init();
    defer std.debug.print("compilation error: {}", .{compile_diag});
    const compile_result = try compiler.compile(a, &third_sexp, null, &compile_diag);
    a.free(compile_result);
}
