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

    pub const Diagnostic = union(enum(u16)) {
        None = 0,
        DuplicateNode: i64,
        MultipleEntries: i64,
        UnknownNodeType: []const u8,
        DoesntReturn: NodeId,

        const Code = error{
            DuplicateNode,
            MultipleEntries,
            UnknownNodeType,
            DoesntReturn,
        };

        pub fn init() @This() {
            return .None;
        }

        pub fn code(self: @This()) Code {
            return switch (self) {
                .None => unreachable,
                .DuplicateNode => Code.DuplicateNode,
                .MultipleEntries => Code.MultipleEntries,
                .UnknownNodeType => Code.UnknownNodeType,
                .DoesntReturn => Code.DoesntReturn,
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
                .DoesntReturn => |v| try writer.print("Expected return at end of control flow but found node#{}", .{v}),
            }
        }

        pub const Contextualized = struct {
            inner: *const Diagnostic,
            graph: *const GraphBuilder,

            pub fn format(
                self: @This(),
                comptime fmt_str: []const u8,
                fmt_opts: std.fmt.FormatOptions,
                writer: anytype,
            ) @TypeOf(writer).Error!void {
                _ = fmt_str;
                _ = fmt_opts;
                switch (self.inner.*) {
                    .None => _ = try writer.write("Not an error"),
                    .DuplicateNode => |v| try writer.print("Duplicate node found. First duplicate id={}", .{v}),
                    .MultipleEntries => |v| try writer.print("Multiple entries found. Second entry id={}", .{v}),
                    .UnknownNodeType => |v| try writer.print("Unknown node type '{s}'", .{v}),
                    .DoesntReturn => |v| {
                        const bad_node = self.graph.nodes.map.getPtr(v) orelse unreachable;
                        try writer.print(
                            \\Expected return node at end of control flow,
                            \\but instead node#{} is of type '{s}'
                        , .{ v, bad_node._desc.name() });
                    },
                }
            }
        };

        pub fn contextualize(self: *const @This(), graph: *const GraphBuilder) Contextualized {
            return Contextualized{ .inner = self, .graph = graph };
        }
    };

    // TODO: make errors stable somehow
    pub const Diagnostics = struct {
        // NOTE: this means they are read backwards, consider a reverse singly linked list
        list: std.SinglyLinkedList(Diagnostic) = .{},
        arena: std.heap.ArenaAllocator,

        pub fn hasError(self: *const @This()) bool {
            return self.list.first != null;
        }

        pub fn init() @This() {
            return .{
                // FIXME: test if this is efficient
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            const alloc = self.arena.allocator();
            while (self.list.popFirst()) |item| {
                alloc.destroy(item);
            }
            self.arena.deinit();
        }

        pub fn addDiagnostic(self: *@This(), diagnostic: Diagnostic) std.mem.Allocator.Error!void {
            const alloc = self.arena.allocator();
            const new_node = try alloc.create(std.SinglyLinkedList(Diagnostic).Node);
            new_node.* = .{ .data = diagnostic };
            self.list.prepend(new_node);
        }

        pub const Contextualized = struct {
            inner: *const Diagnostics,
            graph: *const GraphBuilder,

            pub fn format(
                self: @This(),
                comptime fmt_str: []const u8,
                fmt_opts: std.fmt.FormatOptions,
                writer: anytype,
            ) @TypeOf(writer).Error!void {
                _ = fmt_str;
                _ = fmt_opts;
                var next = self.inner.list.first;
                while (next) |curr| : (next = curr.next) {
                    _ = try writer.print("{}\n\n", .{curr.data.contextualize(self.graph)});
                }
            }
        };

        pub fn contextualize(self: *const @This(), graph: *const GraphBuilder) Contextualized {
            return Contextualized{ .inner = self, .graph = graph };
        }
    };

    pub fn entry(self: *const @This()) ?*IndexedNode {
        return if (self.entry_id) |entry_id| self.nodes.map.getPtr(entry_id) orelse unreachable else null;
    }

    // FIXME: replace pointers with indices into an allocator? Could be faster
    pub fn isJoin(self: @This(), node: *const IndexedNode) bool {
        return self.is_join_set.isSet(node.id);
    }

    pub fn format(
        self: *const @This(),
        comptime fmt_str: []const u8,
        fmt_opts: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt_str;
        _ = fmt_opts;

        var node_iter = self.nodes.map.iterator();
        while (node_iter.next()) |pair| {
            try writer.print("node#{} '{s}': ", .{ pair.key_ptr.*, pair.value_ptr._desc.name() });
            for (pair.value_ptr.inputs) |input| {
                switch (input) {
                    .link => |link_| if (link_) |v| try writer.print("{}/{}->.", .{ v.target, v.pin_index }) else std.debug.print("!!", .{}),
                    .value => |v| try writer.print("{}", .{v}),
                }
                try writer.print(", ", .{});
            }

            try writer.print("; ", .{});

            for (pair.value_ptr.outputs) |output| {
                if (output) |o| try writer.print(".->{}/{}", .{ o.link.target, o.link.pin_index }) else try writer.print("!!", .{});
                try writer.print(", ", .{});
            }

            try writer.print("\n", .{});
        }
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
                .kind = .entry,
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
                .kind = .return_,
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
        //self.addEdge(alloc, entry_id, 0, return_id, 0, 0) catch unreachable;

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

        self.locals.deinit(alloc);
        self.imports.deinit(alloc);

        self.branch_joiner_map.deinit(alloc);
        self.is_join_set.deinit(alloc);
        {
            var node_iter = self.nodes.map.iterator();
            while (node_iter.next()) |*node| {
                node.value_ptr.deinit(alloc);
            }
        }
        self.nodes.deinit(alloc);
    }

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
    pub fn addEdge(self: @This(), alloc: std.mem.Allocator, start_id: NodeId, start_index: u16, end_id: NodeId, end_index: u16, end_subindex: u16) !void {
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
            std.log.err("start_index {} not valid, only {} available outputs\n", .{ start_index, start.outputs.len });
            return error.SourceIndexInvalid;
        }

        if (end_index >= end.inputs.len) {
            // TODO: return diagnostic
            std.log.err("end_index {} not valid, only {} available inputs\n", .{ end_index, end.inputs.len });
            return error.TargetIndexInvalid;
        }

        try start.outputs[start_index].append(alloc, .{
            .target = end_id,
            .pin_index = end_index,
            .sub_index = end_subindex,
        });

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

        {
            var iter = start.outputs[start_index].links.iterator(0);
            while (iter.next()) |link| {
                if (link.target == end_id and link.sub_index == end_index) {
                    link.* = helpers.GraphTypes.dead_outlink;
                    start.outputs[start_index].dead_count += 1;
                    break;
                }
            }
        }

        // FIXME: should have a function to choose the default for a disconnected pin
        end.inputs[end_index] = .{ .value = .{ .int = 0 } };
    }

    pub fn removeOutputLinks(self: *@This(), node_id: NodeId, output_index: u16) !void {
        const node = self.nodes.map.getPtr(node_id) orelse return error.SourceNodeNotFound;
        var output = if (output_index >= node.outputs.len) return error.SourceIndexInvalid else node.outputs[output_index];

        var iter = output.links.iterator(0);
        var i: u32 = 0;
        while (iter.next()) |link| : (i += 1) {
            if (link.isDeadOutput()) continue;
            // TODO: diagnostic
            const target_node = self.nodes.map.getPtr(node_id) orelse {
                std.log.err("TargetNodeNotFound={}", .{i});
                return error.TargetNodeNotFound;
            };
            // FIXME: need a function for resetting pins of any type, they probably default to 0
            target_node.inputs[link.pin_index] = .{ .value = .{ .int = 0 } };
        }

        output.links.clearRetainingCapacity();
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
    pub fn compile(self: *@This(), alloc: std.mem.Allocator, name: []const u8, diagnostic: ?*Diagnostics) !Sexp {
        try self.branch_joiner_map.ensureTotalCapacity(alloc, self.branch_count);
        try self.is_join_set.resize(alloc, self.nodes.map.count(), false);

        // FIXME: this causes a crash in non-debug builds
        var analysis_arena = std.heap.ArenaAllocator.init(alloc);
        try self.analyzeNodes(alloc);
        analysis_arena.deinit();

        var body = try self.rootToSexp(alloc, diagnostic);
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
                    for (collapsed_node.outputs, collapsed_node.desc().getOutputs()) |outputs, output_desc| {
                        if (!output_desc.isExec()) continue;
                        std.debug.assert(outputs.links.len <= 1);
                        if (outputs.links.len == 0) continue;
                        const output = outputs.getExecOutput();
                        const target = self.nodes.map.getPtr(output.target) orelse unreachable;
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

    /// FIXME: document overall algorithm:
    const ToSexp = struct {
        graph: *const GraphBuilder,
        // FIXME: this should be multiple diagnostics!
        diagnostics: *Diagnostics,

        const NodeData = packed struct {
            visited: u1,
            depth: u32, // TODO: u31
        };

        pub const Block = std.ArrayList(Sexp);

        const Context = struct {
            // FIXME: um isn't not using a pointer (I copy this context a lot) a bug?
            node_data: std.MultiArrayList(NodeData) = .{},
            block: *Block,
            current_depth: u32 = 0,
            label_counter: u32 = 0,

            pub fn init(alloc: std.mem.Allocator, in_block: *Block, node_count: usize) !@This() {
                var self = @This(){
                    .block = in_block,
                };

                // TODO: can this be done better?
                try self.node_data.resize(alloc, node_count);
                var slices = self.node_data.slice();
                @memset(slices.items(.visited)[0..self.node_data.len], 0);
                @memset(slices.items(.depth)[0..self.node_data.len], 0);

                return self;
            }

            pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
                self.node_data.deinit(a);
            }
        };

        pub fn toSexp(self: @This(), alloc: std.mem.Allocator, node_id: NodeId) !Sexp {
            var block = Block.init(alloc);
            defer {
                for (block.items) |member| member.deinit(alloc);
                block.deinit();
            }
            var ctx = try Context.init(alloc, &block, self.graph.nodes.map.count());
            defer ctx.deinit(alloc);

            try self.onNode(alloc, node_id, &ctx);
            return Sexp{ .value = .{ .list = std.ArrayList(Sexp).fromOwnedSlice(alloc, try ctx.block.toOwnedSlice()) } };
        }

        const Error = error{
            CyclesNotSupported,
            OutOfMemory,
        } || Diagnostic.Code;

        pub fn onNode(self: @This(), alloc: std.mem.Allocator, node_id: NodeId, context: *Context) Error!void {
            // FIXME: not handled
            if (context.node_data.items(.visited)[node_id] == 1) {
                if (context.node_data.items(.depth)[node_id] < context.current_depth)
                    return error.CyclesNotSupported;
                return;
            }

            const node = self.graph.nodes.map.getPtr(node_id) orelse std.debug.panic("onNode: couldn't find node by id={}", .{node_id});

            context.node_data.items(.visited)[node_id] = 1;
            context.node_data.items(.depth)[node_id] = context.current_depth;

            var next_context = Context{
                .node_data = context.node_data,
                .block = context.block,
                .current_depth = context.current_depth + 1,
            };

            return if (node.desc().isSimpleBranch())
                @call(debug_tail_call, onBranchNode, .{ self, alloc, node, &next_context })
            else
                @call(debug_tail_call, onFunctionCallNode, .{ self, alloc, node, &next_context });
        }

        // FIXME: refactor to find joins during this?
        pub fn onBranchNode(self: @This(), alloc: std.mem.Allocator, node: *const IndexedNode, context: *Context) !void {
            std.debug.assert(node.desc().isSimpleBranch());

            var consequence_sexp: Sexp = undefined;
            var alternative_sexp: Sexp = undefined;

            // FIXME: nodes with these constraints should be specialized!
            // TODO: (nodes should also be SoA and EoA'd)
            std.debug.assert(node.outputs[0].links.len <= 1);
            if (node.outputs[0].links.len == 1) {
                const consequence = node.outputs[1].links.at(0);
                var block = Block.init(alloc);
                var consequence_ctx = Context{
                    .node_data = context.node_data,
                    .block = &block,
                };
                // FIXME: only add `begin` if it's multiple expressions
                (try consequence_ctx.block.addOne()).* = syms.begin;
                try self.onNode(alloc, consequence.target, &consequence_ctx);
                consequence_sexp = Sexp{ .value = .{ .list = block } };
            }

            std.debug.assert(node.outputs[1].links.len <= 1);
            if (node.outputs[1].links.len == 1) {
                const alternative = node.outputs[1].links.at(0);
                var block = Block.init(alloc);
                var alternative_ctx = Context{
                    .node_data = context.node_data,
                    .block = &block,
                };
                // FIXME: only add `begin` if it's multiple expressions
                (try alternative_ctx.block.addOne()).* = syms.begin;
                try self.onNode(alloc, alternative.target, &alternative_ctx);
                alternative_sexp = Sexp{ .value = .{ .list = block } };
            }

            var branch_sexp = try context.block.addOne();
            errdefer branch_sexp.deinit(alloc);

            branch_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };

            // (if
            (try branch_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = node.desc().name() } };

            // condition
            const condition_sexp = try self.nodeInputTreeToSexp(alloc, node.inputs[1], context);
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
            if (self.graph.isJoin(node)) // FIXME: why?
                return;

            const name = node._desc.name();

            var sexp = try context.block.addOne();

            // FIXME: doesn't work for variadics
            // FIXME: this must be unified with nodeInputTreeToSexp!
            switch (node.desc().kind) {
                .get => {
                    sexp.* = Sexp{ .value = .{ .symbol = name } };
                },
                .entry => std.debug.panic("nodeInputTreeToSexp should ignore entry nodes", .{}),
                .set, .func, .return_ => {
                    sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                    try sexp.value.list.ensureTotalCapacityPrecise(1 + node.inputs.len - 1);
                    (try sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = name } };

                    for (node.inputs, node.desc().getInputs()) |input, input_desc| {
                        std.debug.assert(input_desc.kind == .primitive);
                        switch (input_desc.kind.primitive) {
                            .exec => {},
                            .value => {
                                const input_tree = try self.nodeInputTreeToSexp(alloc, input, context);
                                std.log.info("node={s}, func input: {}", .{ node._desc.name(), input_tree });
                                (try sexp.value.list.addOne()).* = input_tree;
                            },
                        }
                    }

                    var next_node: ?NodeId = null;
                    for (node.outputs, node.desc().getOutputs()) |output, output_desc| {
                        if (output_desc.kind.primitive == .exec)
                            std.debug.assert(output.links.len <= 1);
                        if (output.links.len == 1 and output_desc.kind.primitive == .exec) {
                            next_node = output.links.uncheckedAt(0).target;
                        }
                    }

                    if (next_node == null and node.desc().kind != .return_) {
                        try self.diagnostics.addDiagnostic(.{ .DoesntReturn = node.id });
                        return Diagnostic.Code.DoesntReturn;
                    }

                    // FIXME: refactor to always have exactly one output in the non-pure function call case
                    // so we can tail call
                    //return @call(debug_tail_call, onNode, .{ self, alloc, node.outputs[0].?.link.target, context });
                    if (next_node) |next_id|
                        try self.onNode(alloc, next_id, context);
                },
            }
        }

        fn nodeInputTreeToSexp(self: @This(), alloc: std.mem.Allocator, in_link: GraphTypes.Input, context: *Context) !Sexp {
            switch (in_link) {
                .link => |link| {
                    const source_node = self.graph.nodes.map.getPtr(link.target) orelse std.debug.panic("couldn't find link target id={}", .{link.target});

                    var sexp = _: {
                        const name = source_node.desc().name();

                        switch (source_node._desc.kind) {
                            .get => break :_ Sexp{ .value = .{ .symbol = name } },
                            .entry => {
                                break :_ Sexp{ .value = .{ .symbol = source_node.desc().getOutputs()[link.pin_index].name } };
                            },
                            .set, .func, .return_ => {
                                var result = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };

                                try result.value.list.ensureTotalCapacityPrecise(source_node.inputs.len + 1);

                                result.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = name } };

                                // HACK, skip control flow inputs for function calls (currently math is marked as a function but
                                // should be marked as pure)
                                const inputs = if (source_node._desc.getOutputs()[0].isExec()) source_node.inputs[1..] else source_node.inputs;

                                // skip the control flow input
                                for (inputs) |input| {
                                    result.value.list.addOneAssumeCapacity().* = try self.nodeInputTreeToSexp(alloc, input, context);
                                }

                                break :_ result;
                            },
                        }
                    };

                    if (source_node.outputs[link.pin_index].len() > 1) {
                        // FIXME: generate name from user, and recommend people choose a label
                        const label = std.fmt.allocPrint(alloc, "#!__label{}", .{context.label_counter}) catch unreachable;
                        sexp.label = label;
                        context.block.append(sexp) catch unreachable;

                        const label_ref = std.fmt.allocPrint(alloc, "__label{}", .{context.label_counter}) catch unreachable;

                        context.label_counter += 1;
                        return Sexp{ .value = .{ .symbol = label_ref } };
                    } else {
                        return sexp;
                    }
                },
                // FIXME: move to own func for Value=>Sexp?, or just make Value==Sexp now...
                .value => |v| switch (v) {
                    .int => |u| return Sexp{ .value = .{ .int = u } },
                    .float => |u| return Sexp{ .value = .{ .float = u } },
                    .string => |u| return Sexp{ .value = .{ .borrowedString = u } },
                    .bool => |u| return Sexp{ .value = .{ .bool = u } },
                    .null => return Sexp{ .value = .void },
                    .symbol => |u| return Sexp{ .value = .{ .symbol = u } },
                },
            }
        }
    };

    fn rootToSexp(self: *@This(), alloc: std.mem.Allocator, diagnostics: ?*Diagnostics) !Sexp {
        if (self.entry_id == null) {
            return error.NoEntryOrNotYetSet;
        }

        std.debug.assert(self.entry().?.desc().getOutputs()[0].isExec());

        if (self.entry().?.outputs[0].links.len == 0)
            return Sexp.newList(alloc);

        if (self.entry().?.outputs[0].links.len > 1)
            return error.ExecCannotBeMultiConnected;

        const after_entry_id = self.entry().?.outputs[0].links.uncheckedAt(0).target;
        var if_empty_diag = Diagnostics.init();
        const diag = if (diagnostics) |d| d else &if_empty_diag;
        return (ToSexp{ .graph = self, .diagnostics = diag }).toSexp(alloc, after_entry_id);
    }
};

// TODO: rework to use errors explicitly
const GraphToSourceErr = union(enum(u16)) {
    None = 0,
    // TODO: remove
    OutOfMemory: void = @intFromError(error.OutOfMemory),
    // TODO: remove
    IoErr: anyerror,

    Compile: GraphBuilder.Diagnostics,
    Read: json.Diagnostics,

    const Code = error{
        IoErr,
        OutOfMemory,
    } || GraphBuilder.Diagnostics.Code || json.Error;

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

    var diagnostic = GraphBuilder.Diagnostic.init();
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

    const entry_index: NodeId = 0;
    const plus1_index = try graph.addNode(a, "+", false, null, &diagnostic);
    const if_index = try graph.addNode(a, "if", false, null, &diagnostic);
    const plus2_index = try graph.addNode(a, "+", false, null, &diagnostic);
    const set_index = try graph.addNode(a, "set!", false, null, &diagnostic);
    const confetti_index = try graph.addNode(a, "throw-confetti", false, null, &diagnostic);
    const return_index = try graph.addNode(a, "return", false, null, null);
    const return2_index = try graph.addNode(a, "return", false, null, null);

    try graph.addLiteralInput(plus1_index, 0, 0, .{ .float = 2.0 });
    try graph.addLiteralInput(plus1_index, 1, 0, .{ .float = 3.0 });
    try graph.addLiteralInput(plus2_index, 0, 0, .{ .float = 4.0 });
    try graph.addLiteralInput(plus2_index, 1, 0, .{ .int = 8 });
    try graph.addLiteralInput(set_index, 1, 0, .{ .symbol = "x" });
    try graph.addLiteralInput(confetti_index, 1, 0, .{ .int = 100 });
    try graph.addLiteralInput(if_index, 1, 0, .{ .bool = false });

    try graph.addEdge(a, entry_index, 0, if_index, 0, 0);
    try graph.addEdge(a, if_index, 0, set_index, 0, 0);
    try graph.addEdge(a, if_index, 1, confetti_index, 0, 0);
    try graph.addEdge(a, confetti_index, 0, return2_index, 0, 0);
    try graph.addEdge(a, plus1_index, 0, return2_index, 1, 0);
    try graph.addEdge(a, plus2_index, 0, set_index, 2, 0);
    try graph.addEdge(a, set_index, 0, return_index, 0, 0);
    try graph.addEdge(a, plus1_index, 0, return_index, 1, 0);
    //try graph.addEdge(a, confetti_index, 0, return_index, 0, 0);

    var diagnostics = GraphBuilder.Diagnostics.init();
    errdefer if (diagnostics.hasError()) std.debug.print("DIAGNOSTICS:\n{}\n", .{diagnostics});
    const sexp = graph.compile(a, "main", &diagnostics) catch |e| {
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
        \\               (+ 2 3) #!__x1
        \\               (if #f
        \\                   (begin (set! x
        \\                                (+ 4
        \\                                   8))
        \\                          (return __x1))
        \\                   (begin (throw-confetti 100)
        \\                          (return __x1)))))
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
//     try graph.addEdge(a, entry_index, 0, confetti_index, 0, 0);
//     try graph.addEdge(a, confetti_index, 0, confetti2_index, 0, 0);
//     try graph.addEdge(a, confetti2_index, 0, return_index, 0, 0);

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

    const return_node = try graph.addNode(a, "return", false, null, null);
    try graph.addEdge(a, 0, 0, return_node, 0, 0);

    const first_sexp = graph.compile(a, "main", null) catch |e| {
        std.debug.print("\ncompile error: {}\n", .{e});
        return e;
    };
    first_sexp.deinit(a);

    const second_sexp = graph.compile(a, "main", null) catch |e| {
        std.debug.print("\ncompile error: {}\n", .{e});
        return e;
    };
    defer second_sexp.deinit(a);

    var text = std.ArrayList(u8).init(a);
    defer text.deinit();
    _ = try second_sexp.write(text.writer());

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
    const compile_result = try compiler.compile(a, &second_sexp, &env, null, &compile_diag);
    a.free(compile_result);
}
