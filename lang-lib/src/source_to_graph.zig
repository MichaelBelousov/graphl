const std = @import("std");
const builtin = @import("builtin");
const io = std.io;
const testing = std.testing;
const assert = std.debug.assert;

const Sexp = @import("./sexp.zig").Sexp;
const SexpParser = @import("./sexp_parser.zig").Parser;
const syms = @import("./sexp.zig").syms;

const Loc = @import("./loc.zig").Loc;

const Env = @import("./nodes/builtin.zig").Env;
const Value = @import("./nodes/builtin.zig").Value;

const GraphTypes = @import("./common.zig").GraphTypes;
const Node = GraphTypes.Node;
const Link = GraphTypes.Link;
const NodeId = GraphTypes.NodeId;
const Graph = @import("./graph_to_source.zig").GraphBuilder;

var Graphs = std.SinglyLinkedList(Graph);

fn funcSourceToGraph(
    a: std.mem.Allocator,
    type_sexp: *const Sexp,
    impl_sexp: *const Sexp,
    env: *Env,
) !Graph {
    const graph = try Graph.init(a, env);

    assert(type_sexp.value == .list);
    assert(impl_sexp.value == .list);

    const define_kw = &impl_sexp.value.list.items[0];
    assert(define_kw.value.symbol.ptr == syms.define.ptr);

    const typeof_kw = &type_sexp.value.list.items[0];
    assert(typeof_kw.value.symbol.ptr == syms.typeof.ptr);

    const binding_types = &type_sexp.value.list.items[1];
    assert(binding_types.value.list.items.len >= 1);
    for (binding_types.value.list.items) |b| assert(b.value == .symbol);

    const bindings = &impl_sexp.value.list.items[1];
    assert(bindings.value.list.items.len == binding_types.list.items.len);
    for (bindings.value.list.items) |b| assert(b.value == .symbol);

    const param_names = bindings.value.list.items[1..];
    const param_types = binding_types.value.list.items[1..];

    {
        try a.realloc(graph.entry_node_basic_desc.outputs, param_names.len);
        for (param_names, param_types, graph.entry_node_basic_desc.outputs) |param_name, param_type_name, *output_desc| {
            output_desc.name = param_name;
            const param_type = env.getType(param_type_name) orelse unreachable;
            output_desc.kind = .{ .primitive = .{ .value = param_type } };
        }
    }

    const result_type_name = type_sexp.value.list.items[2].value.symbol;
    const result_type = env.getType(result_type_name) orelse unreachable;
    graph.return_node_basic_desc.inputs[1].kind.primitive.value = result_type;

    const definition = &impl_sexp.value.list.items[2];
    assert(definition.value.list.items.len == 1);

    const def_begin = &definition.value.list.items[0];
    assert(def_begin.value.list.items[0].value.symbol.ptr == syms.begin.ptr);

    const full_body = def_begin.value.list.items[1..];
    assert(full_body.len >= 1);

    const first_non_def_index = _: {
        var i: usize = 0;
        for (full_body) |form| {
            i += 1;
            assert(form.value.list.items.len >= 1);
            const callee = &form.value.list.items[0];
            if (callee.value.symbol.ptr != syms.typeof.ptr and callee.value.symbol.ptr != syms.define.ptr)
                break :_ i;
        }
        unreachable;
    };

    const locals_forms = def_begin.value.list.items[0..first_non_def_index];
    const body_exprs = def_begin.value.list.items[first_non_def_index..];

    {
        assert(locals_forms.len % 2 == 0);
        try graph.locals.ensureTotalCapacityPrecise(locals_forms.len / 2);

        var i: usize = 0;
        while (i < locals_forms.len) : (i += 2) {
            const local_type_sexp = &locals_forms[i];
            const local_def_sexp = &locals_forms[i + 1];

            const local_name = local_def_sexp.value.list.items[1].value.symbol;
            const local_type_name = local_type_sexp.value.list.items[2].value.symbol;

            const local_type = env.getType(local_type_name);
            assert(local_type != null);

            graph.locals.addOneAssumeCapacity().* = .{
                .name = local_name,
                .type_ = local_type,
                // FIXME: should add an "extra" to be compatible with the frontend?
                .extra = null,
            };
        }
    }

    var prev_node = graph.entry() orelse unreachable;
    for (body_exprs) |body_expr| {
        const callee = body_expr.value.list.items[0].value.symbol;
        // TODO: this should return the full node and not cause consumers to need to perform a lookup
        const new_node_id = try graph.addNode(a, callee, false, null, null);
        const new_node = graph.nodes.map.getPtr(new_node_id) orelse unreachable;
        assert(new_node.desc().getInputs()[0].isExec());
        assert(prev_node.desc().getOutputs()[0].isExec());
        prev_node.outputs[0] = .{ .link = new_node_id };
        new_node.inputs[0] = .{ .link = prev_node.id };
        prev_node = new_node;
    }

    return graph;
}

fn sexpToGraphs(a: std.mem.Allocator, sexp: *const Sexp, env: *Env) !Graphs {
    const graphs = Graphs{};

    assert(sexp.value == .module);

    // NOTE: assuming typeof is always right before, which has not been explicitly decided upon
    var maybe_prev_typeof: ?*const Sexp = null;
    for (sexp.value.module.items) |top_level| {
        assert(top_level.value == .list);
        assert(top_level.value.list.items.len == 3);
        if (maybe_prev_typeof) |prev_typeof| {
            maybe_prev_typeof = null;
            const define_kw = &top_level.value.list.items[0];
            assert(define_kw.value.symbol.ptr == syms.define);

            const graph_slot = a.create(Graphs.Node);
            graph_slot.* = .{
                .data = try funcSourceToGraph(a, prev_typeof, top_level, env),
            };
        } else {
            const typeof = &top_level.value.list.items[0];
            assert(typeof.value.symbol.ptr == syms.typeof.ptr);
            maybe_prev_typeof = &top_level;
        }
    }

    return graphs;
}

pub fn sourceToGraph(a: std.mem.Allocator, source: []const u8, env: *Env) !Graph {
    var diag = SexpParser.Diagnostic{};
    if (SexpParser.parse(a, source, &diag)) |sexp| {
        return funcSourceToGraph(a, &sexp, env);
    } else |err| {
        std.log.err("bad sexp:\n{}\n", .{err});
        return err;
    }
}
