//! FIXME: wouldn't it be nice if I could just use Sexp as the in-memory format
//! of the graph? Not sure how feasible it is, but if each "node" renders its edges,
//! then maybe a valref can just render an edge?
//! Of course also need a "position" (for now) for each sexp in another arena, and maybe
//! some other stuff

const std = @import("std");
const builtin = @import("builtin");
const io = std.io;
const testing = std.testing;
const assert = std.debug.assert;

const graphl = @import("graphl_core");

const ModuleContext = graphl.ModuleContext;
const Sexp = graphl.Sexp;
const SexpParser = graphl.SexpParser;
const syms = graphl.syms;

const Env = graphl.helpers.Env;
const Value = graphl.helpers.Value;

const Node = graphl.Node;
const Link = graphl.Link;
const NodeId = graphl.NodeId;
const App = @import("./app.zig");
const Graph = App.Graph;

const Graphs = std.SinglyLinkedList(Graph);

fn funcSourceToGraph(
    // NOTE: for now this must be gpa...
    a: std.mem.Allocator,
    app: *App,
    mod: *const ModuleContext,
    type_sexp_idx: u32,
    impl_sexp_idx: u32,
    index: u16,
    env: *Env,
) !Graph {
    const type_sexp = mod.get(type_sexp_idx);
    const impl_sexp = mod.get(impl_sexp_idx);

    assert(type_sexp.value == .list);
    assert(impl_sexp.value == .list);

    const define_kw = mod.get(impl_sexp.value.list.items[0]);
    assert(define_kw.value.symbol.ptr == syms.define.value.symbol.ptr);

    const typeof_kw = mod.get(type_sexp.value.list.items[0]);
    assert(typeof_kw.value.symbol.ptr == syms.typeof.value.symbol.ptr);

    const binding_types = mod.get(type_sexp.value.list.items[1]);
    assert(binding_types.value.list.items.len >= 1);
    for (binding_types.value.list.items) |b| assert(mod.get(b).value == .symbol);

    const bindings = mod.get(impl_sexp.value.list.items[1]);
    assert(bindings.value.list.items.len == binding_types.value.list.items.len);
    for (bindings.value.list.items) |b| assert(mod.get(b).value == .symbol);

    const impl_func_name = mod.get(bindings.value.list.items[0]);
    const type_func_name = mod.get(binding_types.value.list.items[0]);
    assert(impl_func_name.value.symbol.ptr == type_func_name.value.symbol.ptr);

    const func_name = try a.dupeZ(u8, impl_func_name.value.symbol);

    var graph = try Graph.init(app, index, func_name, .{});

    const param_names = bindings.value.list.items[1..];
    const param_types = binding_types.value.list.items[1..];

    {
        graph.graphl_graph.entry_node_basic_desc.outputs = try a.realloc(graph.graphl_graph.entry_node_basic_desc.outputs, param_names.len);
        for (param_names, param_types, graph.graphl_graph.entry_node_basic_desc.outputs) |param_name_idx, param_type_name_idx, *output_desc| {
            const param_name = mod.get(param_name_idx);
            const param_type_name = mod.get(param_type_name_idx);
            output_desc.name = param_name.value.symbol;
            const param_type = env.getType(param_type_name.value.symbol) orelse unreachable;
            output_desc.kind = .{ .primitive = .{ .value = param_type } };
        }
    }

    const result_type = mod.get(type_sexp.value.list.items[2]);
    const result_types_count: usize = switch (result_type.value) {
        .list, .module => |v| v.items.len,
        .symbol => 1,
        else => return error.InvalidReturnTypeSyntax,
    };
    const result_types_idxs = switch (result_type.value) {
        .list, .module => |v| v.items,
        .symbol => &.{type_sexp.value.list.items[2]},
        else => unreachable,
    };

    // FIXME: make the owner/lifetime of this easier to understand
    graph.graphl_graph.result_node_basic_desc.inputs = try a.realloc(graph.graphl_graph.result_node_basic_desc.inputs, 1 + result_types_count);
    for (
        graph.graphl_graph.result_node_basic_desc.inputs[1..],
        result_types_idxs,
    ) |*input, result_type_idx| {
        const result_subtype_name = mod.get(result_type_idx).value.symbol;
        const result_subtype = env.getType(result_subtype_name) orelse unreachable;
        // FIXME: for name slice into a preallocated list of number strings
        input.* = .{ .name = "", .kind = .{ .primitive = .{ .value = result_subtype } } };
    }

    const definition = mod.get(impl_sexp.value.list.items[2]);
    assert(definition.value.list.items.len >= 2);

    const def_begin = mod.get(definition.value.list.items[0]);
    assert(def_begin.value.symbol.ptr == syms.begin.value.symbol.ptr);

    const full_body = definition.value.list.items[1..];
    assert(full_body.len >= 1);

    const first_non_def_index = _: {
        var i: usize = 0;
        for (full_body) |form_idx| {
            const form = mod.get(form_idx);
            assert(form.value.list.items.len >= 1);
            const callee = mod.get(form.value.list.items[0]);
            if (callee.value.symbol.ptr != syms.typeof.value.symbol.ptr
                //
            and callee.value.symbol.ptr != syms.define.value.symbol.ptr)
                break :_ i;
            i += 1;
        }
        unreachable;
    };

    const locals_forms = full_body[0..first_non_def_index];
    const body_exprs = full_body[first_non_def_index..];

    {
        assert(locals_forms.len % 2 == 0);
        try graph.graphl_graph.locals.ensureTotalCapacityPrecise(a, locals_forms.len / 2);

        var i: usize = 0;
        while (i < locals_forms.len) : (i += 2) {
            const local_type_sexp_idx = locals_forms[i];
            const local_def_sexp_idx = locals_forms[i + 1];

            const local_type_sexp = mod.get(local_type_sexp_idx);
            const local_def_sexp = mod.get(local_def_sexp_idx);

            const local_name = try a.dupeZ(u8, mod.get(local_def_sexp.value.list.items[1]).value.symbol);
            const local_type_name = mod.get(local_type_sexp.value.list.items[2]).value.symbol;

            const local_type = env.getType(local_type_name) orelse unreachable;

            graph.graphl_graph.locals.appendAssumeCapacity(.{
                .name = local_name,
                .type_ = local_type,
                // FIXME: should add an "extra" to be compatible with the frontend?
                .extra = null,
            });
        }
    }

    const node_for_sexp = try a.alloc(NodeId, mod.arena.items.len);
    defer a.free(node_for_sexp);

    const Local = struct {
        pub fn attachArgs(
            _a: std.mem.Allocator,
            node: *Node,
            args: []const u32,
            _env: *Env,
            _graph: *Graph,
            _mod: *const ModuleContext,
            _node_for_sexp: @TypeOf(node_for_sexp),
        ) !void {
            for (args, node.inputs) |arg_idx, *input| {
                const arg = _mod.get(arg_idx);
                switch (arg.value) {
                    .list => |v| {
                        assert(v.items.len >= 1);
                        const callee = _mod.get(v.items[0]);
                        const input_args = v.items[1..];
                        assert(callee.value == .symbol);
                        const input_node_id = try _graph.addNode(_a, callee.value.symbol, false, null, null, .{});
                        _node_for_sexp[arg_idx] = input_node_id;
                        const input_node = _graph.graphl_graph.nodes.map.getPtr(input_node_id) orelse unreachable;
                        try attachArgs(_a, input_node, input_args, _env, _graph, _mod, _node_for_sexp);
                        input.link = .{
                            .target = input_node_id,
                            .pin_index = 0, // FIXME: here I assume all nodes have 1 output
                        };
                    },
                    .int => |v| {
                        input.value.int = v;
                    },
                    .float => |v| {
                        input.value.float = v;
                    },
                    .void => |v| {
                        input.value.null = v;
                    },
                    .symbol => |v| {
                        input.value.symbol = v;
                    },
                    // TODO: dupe
                    .ownedString, .borrowedString => |v| {
                        input.value.string = v;
                    },
                    .bool => |v| {
                        input.value.bool = v;
                    },
                    .module => unreachable,
                    .jump => |_| {
                        // need to know previous one to do this!
                        //const target = _node_for_sexp[v.target];
                        unreachable;
                    },
                    .valref => |_| {
                        unreachable;
                    },
                }
            }
        }
    };

    var prev_node = graph.graphl_graph.entry() orelse unreachable;
    for (body_exprs) |body_expr_idx| {
        const body_expr = mod.get(body_expr_idx);
        const callee = mod.get(body_expr.value.list.items[0]).value.symbol;
        const args = body_expr.value.list.items[1..];
        // TODO: this should return the full node and not cause consumers to need to perform a lookup
        const new_node_id = try graph.addNode(a, callee, false, null, null, .{});
        const new_node = graph.graphl_graph.nodes.map.getPtr(new_node_id) orelse unreachable;
        assert(new_node.desc().getInputs()[0].isExec());
        assert(prev_node.desc().getOutputs()[0].isExec());
        prev_node.outputs[0] = .{};
        try prev_node.outputs[0].append(a, .{
            .target = new_node_id,
            .pin_index = 0,
        });
        new_node.inputs[0] = .{ .link = .{ .target = prev_node.id, .pin_index = 0 } };
        // FIXME: won't work for if duh
        try Local.attachArgs(a, new_node, args, env, &graph, mod, node_for_sexp);
    }

    try graph.visual_graph.formatGraphNaive(a);

    return graph;
}

fn sexpToGraphs(a: std.mem.Allocator, app: *App, mod_ctx: *const ModuleContext, env: *Env) !Graphs {
    var graphs = Graphs{};
    var index: u16 = 0;

    // NOTE: assuming typeof is always right before, which has not been explicitly decided upon
    var maybe_prev_typeof: ?u32 = null;
    for (mod_ctx.getRoot().body().items) |top_level_idx| {
        const top_level = mod_ctx.get(top_level_idx);
        if (top_level.body().items.len == 0)
            return error.BadTopLevelForm;
        const callee_idx = top_level.body().items[0];
        const callee = mod_ctx.get(callee_idx);

        if (callee.value.symbol.ptr == syms.import.value.symbol.ptr)
            continue;

        if (callee.value.symbol.ptr == syms.meta.value.symbol.ptr)
            continue;

        assert(top_level.value == .list);
        assert(top_level.value.list.items.len == 3);
        if (maybe_prev_typeof) |prev_typeof| {
            maybe_prev_typeof = null;
            const define_kw = mod_ctx.get(top_level.value.list.items[0]);
            assert(define_kw.value.symbol.ptr == syms.define.value.symbol.ptr);

            const graph_slot = try a.create(Graphs.Node);
            graph_slot.* = .{
                .data = try funcSourceToGraph(a, app, mod_ctx, prev_typeof, top_level_idx, index, env),
            };
            graphs.prepend(graph_slot);
            index += 1;
        } else {
            const typeof_idx = top_level.value.list.items[0];
            const typeof = mod_ctx.get(typeof_idx);
            assert(typeof.value.symbol.ptr == syms.typeof.value.symbol.ptr);
            maybe_prev_typeof = top_level_idx;
        }
    }

    return graphs;
}

pub fn sourceToGraph(a: std.mem.Allocator, app: *App, source: []const u8, env: *Env) !Graphs {
    var diag = SexpParser.Diagnostic{ .source = source };
    if (SexpParser.parse(a, source, &diag)) |parsed| {
        return sexpToGraphs(a, app, &parsed.module, env);
    } else |err| {
        std.log.err("bad sexp:\n{}\n", .{err});
        return err;
    }
}
