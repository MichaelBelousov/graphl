const std = @import("std");
const builtin = @import("builtin");
const io = std.io;
const testing = std.testing;
const assert = std.debug.assert;

const grappl = @import("grappl_core");

const Sexp = grappl.Sexp;
const SexpParser = grappl.SexpParser;
const syms = grappl.syms;

const Env = grappl.helpers.Env;
const Value = grappl.helpers.Value;

const Node = grappl.Node;
const Link = grappl.Link;
const NodeId = grappl.NodeId;
const Graph = @import("./app.zig").Graph;

const Graphs = std.SinglyLinkedList(Graph);

fn funcSourceToGraph(
    // NOTE: for now this must be gpa...
    a: std.mem.Allocator,
    type_sexp: *const Sexp,
    impl_sexp: *const Sexp,
    index: u16,
    env: *Env,
) !Graph {
    var graph = try Graph.init(index, env);

    assert(type_sexp.value == .list);
    assert(impl_sexp.value == .list);

    const define_kw = &impl_sexp.value.list.items[0];
    assert(define_kw.value.symbol.ptr == syms.define.value.symbol.ptr);

    const typeof_kw = &type_sexp.value.list.items[0];
    assert(typeof_kw.value.symbol.ptr == syms.typeof.value.symbol.ptr);

    const binding_types = &type_sexp.value.list.items[1];
    assert(binding_types.value.list.items.len >= 1);
    for (binding_types.value.list.items) |b| assert(b.value == .symbol);

    const bindings = &impl_sexp.value.list.items[1];
    assert(bindings.value.list.items.len == binding_types.value.list.items.len);
    for (bindings.value.list.items) |b| assert(b.value == .symbol);

    const param_names = bindings.value.list.items[1..];
    const param_types = binding_types.value.list.items[1..];

    {
        graph.entry_node_basic_desc.outputs = try a.realloc(graph.entry_node_basic_desc.outputs, param_names.len);
        for (param_names, param_types, graph.entry_node_basic_desc.outputs) |param_name, param_type_name, *output_desc| {
            output_desc.name = try a.dupe(u8, param_name.value.symbol);
            const param_type = env.getType(param_type_name.value.symbol) orelse unreachable;
            output_desc.kind = .{ .primitive = .{ .value = param_type } };
        }
    }

    const result_type_name = type_sexp.value.list.items[2].value.symbol;
    const result_type = env.getType(result_type_name) orelse unreachable;
    graph.result_node_basic_desc.inputs[1].kind.primitive.value = result_type;

    const definition = &impl_sexp.value.list.items[2];
    assert(definition.value.list.items.len == 1);

    const def_begin = &definition.value.list.items[0];
    assert(def_begin.value.list.items[0].value.symbol.ptr == syms.begin.value.symbol.ptr);

    const full_body = def_begin.value.list.items[1..];
    assert(full_body.len >= 1);

    const first_non_def_index = _: {
        var i: usize = 0;
        for (full_body) |form| {
            i += 1;
            assert(form.value.list.items.len >= 1);
            const callee = &form.value.list.items[0];
            if (callee.value.symbol.ptr != syms.typeof.value.symbol.ptr and callee.value.symbol.ptr != syms.define.value.symbol.ptr)
                break :_ i;
        }
        unreachable;
    };

    const locals_forms = def_begin.value.list.items[0..first_non_def_index];
    const body_exprs = def_begin.value.list.items[first_non_def_index..];

    {
        assert(locals_forms.len % 2 == 0);
        try graph.locals.ensureTotalCapacityPrecise(a, locals_forms.len / 2);

        var i: usize = 0;
        while (i < locals_forms.len) : (i += 2) {
            const local_type_sexp = &locals_forms[i];
            const local_def_sexp = &locals_forms[i + 1];

            const local_name = local_def_sexp.value.list.items[1].value.symbol;
            const local_type_name = local_type_sexp.value.list.items[2].value.symbol;

            const local_type = env.getType(local_type_name) orelse unreachable;

            graph.locals.addOneAssumeCapacity().* = .{
                .name = try a.dupe(u8, local_name),
                .type_ = local_type,
                // FIXME: should add an "extra" to be compatible with the frontend?
                .extra = null,
            };
        }
    }

    const Local = struct {
        pub fn attachArgs(
            _a: std.mem.Allocator,
            node: *Node,
            args: []Sexp,
            _env: *Env,
            _graph: *Graph,
        ) !void {
            for (args, node.inputs) |arg, *input| {
                switch (arg.value) {
                    .list => |v| {
                        assert(v.items.len >= 1);
                        const callee = v.items[0];
                        const input_args = v.items[1..];
                        assert(callee.value == .symbol);
                        const input_node_id = try _graph.addNode(_a, callee.value.symbol, false, null, null);
                        const input_node = _graph.nodes.map.getPtr(input_node_id) orelse unreachable;
                        try attachArgs(_a, input_node, input_args, _env, _graph);
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
                    // TODO: dupe
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
                }
            }
        }
    };

    var prev_node = graph.entry() orelse unreachable;
    for (body_exprs) |body_expr| {
        const callee = body_expr.value.list.items[0].value.symbol;
        const args = body_expr.value.list.items[1..];
        // TODO: this should return the full node and not cause consumers to need to perform a lookup
        const new_node_id = try graph.addNode(a, callee, false, null, null);
        const new_node = graph.nodes.map.getPtr(new_node_id) orelse unreachable;
        assert(new_node.desc().getInputs()[0].isExec());
        assert(prev_node.desc().getOutputs()[0].isExec());
        prev_node.outputs[0] = .{ .link = .{
            .target = new_node_id,
            .pin_index = 0,
        } };
        new_node.inputs[0] = .{ .link = .{ .target = prev_node.id, .pin_index = 0 } };
        // FIXME: won't work for if duh
        try Local.attachArgs(a, new_node, args, env, &graph);
    }

    return graph;
}

fn sexpToGraphs(a: std.mem.Allocator, sexp: *const Sexp, env: *Env) !Graphs {
    var graphs = Graphs{};
    var index: u16 = 0;

    assert(sexp.value == .module);

    // NOTE: assuming typeof is always right before, which has not been explicitly decided upon
    var maybe_prev_typeof: ?*const Sexp = null;
    for (sexp.value.module.items) |top_level| {
        assert(top_level.value == .list);
        assert(top_level.value.list.items.len == 3);
        if (maybe_prev_typeof) |prev_typeof| {
            maybe_prev_typeof = null;
            const define_kw = &top_level.value.list.items[0];
            assert(define_kw.value.symbol.ptr == syms.define.value.symbol.ptr);

            const graph_slot = try a.create(Graphs.Node);
            graph_slot.* = .{
                .data = try funcSourceToGraph(a, prev_typeof, &top_level, index, env),
            };
            graphs.prepend(graph_slot);
            index += 1;
        } else {
            const typeof = &top_level.value.list.items[0];
            assert(typeof.value.symbol.ptr == syms.typeof.value.symbol.ptr);
            maybe_prev_typeof = &top_level;
        }
    }

    return graphs;
}

pub fn sourceToGraph(a: std.mem.Allocator, source: []const u8, env: *Env) !Graphs {
    var diag = SexpParser.Diagnostic{ .source = source };
    if (SexpParser.parse(a, source, &diag)) |sexp| {
        return sexpToGraphs(a, &sexp, env);
    } else |err| {
        std.log.err("bad sexp:\n{}\n", .{err});
        return err;
    }
}
