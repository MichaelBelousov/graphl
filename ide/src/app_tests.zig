const std = @import("std");
const App = @import("./app.zig");
const graphl = @import("graphl_core");
const gpa = @import("./app.zig").gpa;
const compiled_prelude = graphl.compiler.compiled_prelude;

var transfer_buffer: [1024]u8 = undefined;

test "call double" {
    // TODO: use testing allocator
    const a = gpa;

    var app: App = undefined;
    try app.init(.{ .transfer_buffer = &transfer_buffer });

    const user_funcs: []const graphl.compiler.UserFunc = &.{
        graphl.compiler.UserFunc{
            .id = 0,
            .node = .{
                .name = try a.dupe(u8, "confetti"),
                .inputs = try a.dupe(graphl.Pin, &.{
                    graphl.Pin{
                        .name = try a.dupe(u8, "in"),
                        .kind = .{ .primitive = .exec },
                    },
                    graphl.Pin{
                        .name = try a.dupe(u8, "particleCount"),
                        .kind = .{ .primitive = .{ .value = graphl.primitive_types.i32_ } },
                    },
                }),
                .outputs = try a.dupe(graphl.Pin, &.{
                    graphl.Pin{
                        .name = try a.dupe(u8, "out"),
                        .kind = .{ .primitive = .exec },
                    },
                }),
            },
        },
    };

    try app.init(.{
        .user_funcs = user_funcs,
    });
    defer app.deinit();

    const main_graph = app.current_graph;

    {
        // entry ----------> return
        //    a1 -.    * --> .
        //         `-> .
        //             2
        const double_graph = try app.addGraph(try a.dupe(u8, "double"), true, .{});
        try app.addParamOrResult(double_graph.grappl_graph.entry_node, double_graph.grappl_graph.entry_node_basic_desc, .params, null, null);
        try app.addParamOrResult(double_graph.grappl_graph.result_node, double_graph.grappl_graph.result_node_basic_desc, .results, null, null);
        // FIXME: make it possible to call app.NodeAdder()?
        const mul_node_id = try App.NodeAdder.addNode(&app, "*", .{ .kind = .output, .index = 1, .node_id = double_graph.grappl_graph.entry_id orelse unreachable }, .{}, 0);
        const return_id = try App.NodeAdder.addNode(&app, "return", .{ .kind = .output, .index = 0, .node_id = 0 }, .{}, 0);
        try double_graph.addLiteralInput(mul_node_id, 1, 0, .{ .int = 2 });
        try double_graph.addEdge(a, mul_node_id, 0, return_id, 1, 0);
    }

    app.current_graph = main_graph;

    {
        // add a return result of i32
        try app.addParamOrResult(main_graph.grappl_graph.result_node, main_graph.grappl_graph.result_node_basic_desc, .results, null, null);
        // entry --> confetti --> double --------> return
        //           100          10   . --------> .
        const confetti_node_id = try App.NodeAdder.addNode(&app, "confetti", .{ .kind = .output, .index = 0, .node_id = 0 }, .{}, 0);
        try main_graph.addLiteralInput(confetti_node_id, 1, 0, .{ .int = 100 });
        const double_node_id = try App.NodeAdder.addNode(&app, "double", .{ .kind = .output, .index = 0, .node_id = confetti_node_id }, .{}, 0);
        try main_graph.addLiteralInput(double_node_id, 1, 0, .{ .int = 10 });
        const return_id = try App.NodeAdder.addNode(&app, "return", .{ .kind = .output, .index = 0, .node_id = double_node_id }, .{}, 0);
        try main_graph.addEdge(a, double_node_id, 1, return_id, 1, 0);
    }

    var combined = try app.combineGraphs();
    defer combined.deinit(gpa);

    // ;;; so why not this?
    //        (begin (confetti 100)
    //               (return (double 10))))
    // ;;; because I'm not ready to specify how pure functions work
    try std.testing.expectFmt(
        \\(typeof (main)
        \\        i32)
        \\(define (main)
        \\        (begin (confetti 100)
        \\               (double 10) #!__label1
        \\               (return __label1)))
        \\(typeof (double i32)
        \\        i32)
        \\(define (double a1)
        \\        (begin (return (* a1
        \\                          2))))
    , "{}", .{combined});

    // FIXME: use testing allocator
    var diagnostic = graphl.compiler.Diagnostic.init();
    errdefer if (diagnostic.err != .None) std.debug.print("diagnostic: {}", .{diagnostic});

    // imports could be in arbitrary order so just slice it off cuz length will
    // be the same
    const expected_prelude =
        \\(module
        \\(import "env"
        \\        "callUserFunc_i32_R"
        \\        (func $callUserFunc_i32_R
        \\              (param i32)
        \\              (param i32)))
        \\(global $__grappl_vstkp
        \\        (mut i32)
        \\        (i32.const 4096))
        \\
    ++ compiled_prelude ++
        \\
        \\
    ;

    const expected =
        \\(func $confetti
        \\      (param $param_0
        \\             i32)
        \\      (call $callUserFunc_i32_R
        \\            (i32.const 0)
        \\            (local.get $param_0)))
        \\(export "main"
        \\        (func $main))
        \\(type $typeof_main
        \\      (func (result i32)))
        \\(func $main
        \\      (result i32)
        \\      (local $__frame_start
        \\             i32)
        \\      (local $__lc0
        \\             i32)
        \\      (local.set $__frame_start
        \\                 (global.get $__grappl_vstkp))
        \\      (call $confetti
        \\            (i32.const 100))
        \\      (call $double
        \\            (i32.const 10))
        \\      (local.set $__lc0)
        \\      (local.get $__lc0)
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\(export "double"
        \\        (func $double))
        \\(type $typeof_double
        \\      (func (param i32)
        \\            (result i32)))
        \\(func $double
        \\      (param $param_a1
        \\             i32)
        \\      (result i32)
        \\      (local $__frame_start
        \\             i32)
        \\      (local.set $__frame_start
        \\                 (global.get $__grappl_vstkp))
        \\      (i32.mul (local.get $param_a1)
        \\               (i32.const 2))
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\)
    ;

    const wat = try graphl.compiler.compile(gpa, &combined, &app.shared_env, &app.user_funcs, &diagnostic);
    defer gpa.free(wat);

    {
        errdefer std.debug.print("======== prologue: =========\n{s}\n", .{wat[0 .. expected_prelude.len - compiled_prelude.len]});
        try std.testing.expectEqualStrings(expected_prelude[0 .. expected_prelude.len - compiled_prelude.len], wat[0 .. expected_prelude.len - compiled_prelude.len]);
    }
    try std.testing.expectEqualStrings(expected, wat[expected_prelude.len..]);

    try graphl.testing.expectWasmOutput(20, wat, "main", .{});
}

test "call factorial" {
    // TODO: use testing allocator
    const a = gpa;

    var app: App = undefined;
    try app.init(.{ .transfer_buffer = &transfer_buffer });
    defer app.deinit();

    const main_graph = app.current_graph;

    {
        const factorial_graph = try app.addGraph(try a.dupe(u8, "factorial"), true, .{});
        try app.addParamOrResult(factorial_graph.grappl_graph.result_node, factorial_graph.grappl_graph.result_node_basic_desc, .results, null, null);

        const if_node_id = try App.NodeAdder.addNode(&app, "if", .{ .kind = .output, .index = 0, .node_id = 0 }, .{}, 0);
        try app.addParamOrResult(factorial_graph.grappl_graph.entry_node, factorial_graph.grappl_graph.entry_node_basic_desc, .params, null, null);
        const lessthaneq_id = try App.NodeAdder.addNode(&app, "<=", .{ .kind = .output, .index = 1, .node_id = 0 }, .{}, 0);
        try factorial_graph.addLiteralInput(lessthaneq_id, 1, 0, .{ .int = 1 });
        try factorial_graph.addEdge(a, lessthaneq_id, 0, if_node_id, 1, 0);
        const return1_id = try App.NodeAdder.addNode(&app, "return", .{ .kind = .output, .index = 0, .node_id = if_node_id }, .{}, 0);
        try factorial_graph.addLiteralInput(return1_id, 1, 0, .{ .int = 1 });

        const recurse_id = try App.NodeAdder.addNode(&app, "factorial", .{ .kind = .output, .index = 1, .node_id = if_node_id }, .{}, 0);
        const return2_id = try App.NodeAdder.addNode(&app, "return", .{ .kind = .output, .index = 0, .node_id = recurse_id }, .{}, 0);

        const mul_node_id = try App.NodeAdder.addNode(&app, "*", .{ .kind = .output, .index = 1, .node_id = recurse_id }, .{}, 0);
        try factorial_graph.addEdge(a, mul_node_id, 0, return2_id, 1, 0);
        const sub_id = try App.NodeAdder.addNode(&app, "-", .{ .kind = .input, .index = 1, .node_id = recurse_id }, .{}, 0);
        _ = try App.NodeAdder.addNode(&app, "get_a1", .{ .kind = .input, .index = 0, .node_id = sub_id }, .{}, 0);
        try factorial_graph.addLiteralInput(sub_id, 1, 0, .{ .int = 1 });

        _ = try App.NodeAdder.addNode(&app, "get_a1", .{ .kind = .input, .index = 1, .node_id = mul_node_id }, .{}, 0);
    }

    app.current_graph = main_graph;

    {
        try app.addParamOrResult(main_graph.grappl_graph.result_node, main_graph.grappl_graph.result_node_basic_desc, .results, null, null);
        const factorial_node_id = try App.NodeAdder.addNode(&app, "factorial", .{ .kind = .output, .index = 0, .node_id = 0 }, .{}, 0);
        try main_graph.addLiteralInput(factorial_node_id, 1, 0, .{ .int = 10 });
        const return_id = try App.NodeAdder.addNode(&app, "return", .{ .kind = .output, .index = 0, .node_id = factorial_node_id }, .{}, 0);
        try main_graph.addEdge(a, factorial_node_id, 1, return_id, 1, 0);
    }

    var combined = try app.combineGraphs();
    defer combined.deinit(gpa);

    try std.testing.expectFmt(
        \\(typeof (main)
        \\        i32)
        \\(define (main)
        \\        (begin (factorial 10) #!__label1
        \\               (return __label1)))
        \\(typeof (factorial i32)
        \\        i32)
        \\(define (factorial a1)
        \\        (begin (if (<= a1
        \\                       1)
        \\                   (begin (return 1))
        \\                   (begin (factorial (- a1
        \\                                        1)) #!__label1
        \\                          (return (* __label1
        \\                                     a1))))))
    , "{}", .{combined});

    // FIXME: use testing allocator
    var diagnostic = graphl.compiler.Diagnostic.init();
    errdefer if (diagnostic.err != .None) std.debug.print("diagnostic: {}", .{diagnostic});

    // imports could be in arbitrary order so just slice it off cuz length will
    // be the same
    const expected_prelude =
        \\(module
        \\(global $__grappl_vstkp
        \\        (mut i32)
        \\        (i32.const 4096))
        \\
    ++ compiled_prelude ++
        \\
        \\
    ;

    const expected =
        \\(export "main"
        \\        (func $main))
        \\(type $typeof_main
        \\      (func (result i32)))
        \\(func $main
        \\      (result i32)
        \\      (local $__frame_start
        \\             i32)
        \\      (local $__lc0
        \\             i32)
        \\      (local.set $__frame_start
        \\                 (global.get $__grappl_vstkp))
        \\      (call $factorial
        \\            (i32.const 10))
        \\      (local.set $__lc0)
        \\      (local.get $__lc0)
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\(export "factorial"
        \\        (func $factorial))
        \\(type $typeof_factorial
        \\      (func (param i32)
        \\            (result i32)))
        \\(func $factorial
        \\      (param $param_a1
        \\             i32)
        \\      (result i32)
        \\      (local $__frame_start
        \\             i32)
        \\      (local $__lc0
        \\             i32)
        \\      (local.set $__frame_start
        \\                 (global.get $__grappl_vstkp))
        \\      (if (result i32)
        \\          (i32.le_s (local.get $param_a1)
        \\                    (i32.const 1))
        \\          (then (i32.const 1))
        \\          (else (call $factorial
        \\                      (i32.sub (local.get $param_a1)
        \\                               (i32.const 1)))
        \\                (local.set $__lc0)
        \\                (i32.mul (local.get $__lc0)
        \\                         (local.get $param_a1))))
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\)
    ;

    const wat = try graphl.compiler.compile(gpa, &combined, &app.shared_env, &app.user_funcs, &diagnostic);
    defer gpa.free(wat);

    {
        errdefer std.debug.print("======== prologue: =========\n{s}\n", .{wat[0 .. expected_prelude.len - compiled_prelude.len]});
        try std.testing.expectEqualStrings(expected_prelude[0 .. expected_prelude.len - compiled_prelude.len], wat[0 .. expected_prelude.len - compiled_prelude.len]);
    }
    try std.testing.expectEqualStrings(expected, wat[expected_prelude.len..]);

    try graphl.testing.expectWasmOutput(3_628_800, wat, "main", .{});
}

// test "open file" {
//     const confetti_func_id = try app._createUserFunc("confetti", 1, 0);
//     try app._addUserFuncInput(confetti_func_id, 0, "particleCount", .i32_);

//     defer app.deinit();
//     try app.init();

//     const file_content =
//         \\(typeof (main)
//         \\        i32)
//         \\(define (main)
//         \\        (begin (typeof x
//         \\                       i32)
//         \\               (define x)
//         \\               (+ 2 3) #!__x1
//         \\               (if #f
//         \\                   (begin (set! x
//         \\                                (+ 4
//         \\                                   8))
//         \\                          (return __x1))
//         \\                   (begin (throw-confetti 100)
//         \\                          (return __x1)))))
//     ;

//     app.onReceiveLoadedSource(file_content.ptr, file_content.len);

//     // FIXME: assert graph contents

//     var combined = try app.combineGraphs();
//     defer combined.deinit(gpa);

//     try std.testing.expectFmt(file_content, "{}", .{combined});

//     // FIXME: use testing allocator
//     var diagnostic = graphl.compiler.Diagnostic.init();
//     errdefer if (diagnostic.err != .None) std.debug.print("diagnostic: {}", .{diagnostic});

//     const compiled = try graphl.compiler.compile(gpa, &combined, &app.shared_env, &app.user_funcs, &diagnostic);
//     defer gpa.free(compiled);

//     const expected = std.fmt.comptimePrint(
//         \\({s}
//         \\(export "main"
//         \\        (func $main))
//         \\(type $typeof_main
//         \\      (func (result i32)))
//         \\(func $main
//         \\      (result i32)
//         \\      (call $double
//         \\            (i32.const 10)))
//         \\(export "double"
//         \\        (func $double))
//         \\(type $typeof_double
//         \\      (func (param i32)
//         \\            (result i32)))
//         \\(func $double
//         \\      (param $param_a1
//         \\             i32)
//         \\      (result i32)
//         \\      (i32.mul (local.get $param_a1)
//         \\               (i32.const 2)))
//         \\)
//     , .{graphl.compiler.compiled_prelude});

//     try std.testing.expectEqualStrings(expected, compiled);
// }

test "sample1 (if)" {
    // TODO: use testing allocator
    const a = gpa;

    var app: App = undefined;
    try app.init(.{ .transfer_buffer = &transfer_buffer });
    defer app.deinit();

    const main_graph = app.current_graph;

    {
        // entry --> if   then ----------------> return
        //           true else -.      + . ----> .
        //                       `     2
        //                       |     3
        //                       |
        //                       `--> return
        //                            1
        const if_node_id = try App.NodeAdder.addNode(&app, "if", .{ .kind = .output, .index = 0, .node_id = 0 }, .{}, 0);
        try main_graph.addLiteralInput(if_node_id, 1, 0, .{ .bool = true });
        const return1_id = try App.NodeAdder.addNode(&app, "return", .{ .kind = .output, .index = 0, .node_id = if_node_id }, .{}, 0);
        const return2_id = try App.NodeAdder.addNode(&app, "return", .{ .kind = .output, .index = 1, .node_id = if_node_id }, .{}, 0);
        try main_graph.addLiteralInput(return2_id, 1, 0, .{ .int = 1 });
        const plus_node_id = try App.NodeAdder.addNode(&app, "+", null, .{}, 0);
        try main_graph.addLiteralInput(plus_node_id, 0, 0, .{ .int = 2 });
        try main_graph.addLiteralInput(plus_node_id, 1, 0, .{ .int = 3 });
        try main_graph.addEdge(a, plus_node_id, 0, return1_id, 1, 0);
    }

    var combined = try app.combineGraphs();
    defer combined.deinit(gpa);

    try std.testing.expectFmt(
        \\(typeof (main)
        \\        i32)
        \\(define (main)
        \\        (begin (if #t
        \\                   (begin (return (+ 2
        \\                                     3)))
        \\                   (begin (return 1)))))
    , "{}", .{combined});

    // FIXME: use testing allocator
    var diagnostic = graphl.compiler.Diagnostic.init();
    errdefer if (diagnostic.err != .None) std.debug.print("diagnostic: {}", .{diagnostic});

    const compiled = try graphl.compiler.compile(gpa, &combined, &app.shared_env, &app.user_funcs, &diagnostic);
    defer gpa.free(compiled);

    const expected = std.fmt.comptimePrint(
        \\({s}
        \\(export "main"
        \\        (func $main))
        \\(type $typeof_main
        \\      (func (result i32)))
        \\(func $main
        \\      (result i32)
        \\      (if (result i32)
        \\          (i32.const 1)
        \\          (then (i32.add (i32.const 2)
        \\                         (i32.const 3)))
        \\          (else (i32.const 1))))
        \\)
    , .{graphl.compiler.compiled_prelude});

    try std.testing.expectEqualStrings(expected, compiled);

    try graphl.testing.expectWasmOutput(5, compiled, "main", .{});
}

// graphInitState={{
//   notRemovable: true,
//   nodes: [
//     {
//       id: 1,
//       type: "Confetti",
//       inputs: {
//         0: { node: 0, outPin: 0 },
//         1: { int: 100 },
//       },
//       // FIXME: doesn't work
//       position: { x: 200, y: 500 },
//     },
//     {
//       id: 2,
//       type: "return",
//       inputs: {
//         0: { node: 1, outPin: 0 },
//       },
//     },
//   ],
// }}

test "sample3 (sql)" {
    const user_funcs: []const graphl.compiler.UserFunc = &.{
        graphl.compiler.UserFunc{
            .id = 0,
            .node = .{
                .name = "confetti",
                .inputs = &.{
                    graphl.Pin{
                        .name = "in",
                        .kind = .{ .primitive = .exec },
                    },
                    graphl.Pin{
                        .name = "particleCount",
                        .kind = .{ .primitive = .{ .value = graphl.primitive_types.i32_ } },
                    },
                },
                .outputs = &.{
                    graphl.Pin{
                        .name = "in",
                        .kind = .{ .primitive = .exec },
                    },
                },
            },
        },
    };

    var app: App = .{};
    try app.init(.{
        .user_funcs = user_funcs,
    });
    defer app.deinit();

    // const print_query_func_id = try app._createUserFunc("print-query", 1, 0);
    // try app._addUserFuncInput(print_query_func_id, 0, "query", .code);
    // //try app._addUserFuncOutput(print_query_func_id, 0, "string", .string);

    // const select_func_id = try app._createUserFunc("SELECT", 1, 0);
    // try app._addUserFuncInput(select_func_id, 0, "column", .string);

    // const where_func_id = try app._createUserFunc("WHERE", 1, 0);
    // try app._addUserFuncInput(where_func_id, 0, "condition", .bool);

    // const from_func_id = try app._createUserFunc("FROM", 1, 0);
    // try app._addUserFuncInput(from_func_id, 0, "table", .string);

    const main_graph = app.current_graph;

    {
        const print_query_id = try app.NodeAdder.addNode("print-query", .{ .kind = .output, .index = 0, .node_id = 0 }, .{}, 0);
        const return_id = try app.NodeAdder.addNode("return", .{ .kind = .output, .index = 0, .node_id = print_query_id }, .{}, 0);
        _ = return_id;
        const where_id = try app.NodeAdder.addNode("WHERE", .{ .kind = .input, .index = 1, .node_id = print_query_id }, .{}, 0);
        const eq_id = try app.NodeAdder.addNode("==", .{ .kind = .input, .index = 1, .node_id = where_id }, .{}, 0);
        try main_graph.addLiteralInput(eq_id, 1, 0, .{ .int = 2 });
        const make_sym_id = try app.NodeAdder.addNode("make-symbol", .{ .kind = .input, .index = 0, .node_id = eq_id }, .{}, 0);
        try main_graph.addLiteralInput(make_sym_id, 0, 0, .{ .string = "col1" });
        const from_id = try app.NodeAdder.addNode("FROM", .{ .kind = .input, .index = 0, .node_id = where_id }, .{}, 0);
        try main_graph.addLiteralInput(from_id, 1, 0, .{ .string = "table" });
        const select_id = try app.NodeAdder.addNode("SELECT", .{ .kind = .input, .index = 0, .node_id = from_id }, .{}, 0);
        try main_graph.addLiteralInput(select_id, 1, 0, .{ .string = "col1" });
    }

    var combined = try app.combineGraphs();
    defer combined.deinit(gpa);

    try std.testing.expectFmt(
        \\(typeof (main)
        \\        i32)
        \\(define (main)
        \\        (begin (WHERE __label2
        \\                      (== (make-symbol "col1")
        \\                          2)) #!__label3
        \\               (FROM __label1
        \\                     "table") #!__label2
        \\               (SELECT 0
        \\                       "col1") #!__label1
        \\               (print-query __label3)
        \\               (return 0)))
    , "{}", .{combined});

    // FIXME: use testing allocator
    var diagnostic = graphl.compiler.Diagnostic.init();
    errdefer if (diagnostic.err != .None) std.debug.print("diagnostic: {}", .{diagnostic});

    const compiled = try graphl.compiler.compile(gpa, &combined, &app.shared_env, &app.user_funcs, &diagnostic);
    defer gpa.free(compiled);

    const expected = (
        \\(
    ++ graphl.compiler.compiled_prelude ++ "\n" ++
        \\(func $FROM
        \\      (param $param_0
        \\             i32)
        \\      (param $param_1
        \\             i32)
        \\      (call $callUserFunc_string_R
        \\            (i32.const 3)
        \\            (local.get $param_0)
        \\            (local.get $param_1)))
        \\(func $WHERE
        \\      (param $param_0
        \\             i32)
        \\      (call $callUserFunc_bool_R
        \\            (i32.const 2)
        \\            (local.get $param_0)))
        \\(func $SELECT
        \\      (param $param_0
        \\             i32)
        \\      (param $param_1
        \\             i32)
        \\      (call $callUserFunc_string_R
        \\            (i32.const 1)
        \\            (local.get $param_0)
        \\            (local.get $param_1)))
        \\(func $print-query
        \\      (param $param_0
        \\             i32)
        \\      (param $param_1
        \\             i32)
        \\      (call $callUserFunc_code_R
        \\            (i32.const 0)
        \\            (local.get $param_0)
        \\            (local.get $param_1)))
        \\(export "main"
        \\        (func $main))
        \\(type $typeof_main
        \\      (func (result f64)))
        \\(func $main
        \\      (result f64)
        \\      (call $print-query
        \\            (i32.const 330)
        \\            (i32.const 8))
        \\      (f64.const 0))
        \\(data (i32.const 0)
        \\      "J\01\00\00\00\00\00\00{\22entry\22:[{\22symbol\22:\22WHERE\22},{\22symbol\22:\22__label2\22},[{\22symbol\22:\22==\22},[{\22symbol\22:\22make-symbol\22},\22col1\22],2]],\22labels\22:{\22__label2\22:[{\22symbol\22:\22FROM\22},{\22symbol\22:\22__label1\22},\22table\22],\22__label3\22:[{\22symbol\22:\22WHERE\22},{\22symbol\22:\22__label2\22},[{\22symbol\22:\22==\22},[{\22symbol\22:\22make-symbol\22},\22col1\22],2]],\22__label1\22:[{\22symbol\22:\22SELECT\22},0e0,\22col1\22]}}")
        \\)
    );

    try std.testing.expectEqualStrings(expected, compiled);

    try graphl.testing.expectWasmOutput(0, compiled, "main", .{});
}
