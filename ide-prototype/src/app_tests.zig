const std = @import("std");
const app = @import("./app.zig");
const grappl = @import("grappl_core");
const gpa = @import("./app.zig").gpa;

test "call double" {
    const a = std.testing.allocator;

    const confetti_func_id = try app._createUserFunc("confetti", 1, 0);
    try app._addUserFuncInput(confetti_func_id, 0, "particleCount", .i32_);

    defer app.deinit();
    try app.init();

    const main_graph = app.current_graph;

    {
        // entry ----------> return
        //    a1 -.    * --> .
        //         `-> .
        //             2
        const double_graph = try app.addGraph("double", true);
        try app.addParamOrResult(double_graph.grappl_graph.entry_node, double_graph.grappl_graph.entry_node_basic_desc, .params);
        const mul_node_id = try app.NodeAdder.addNode("*", .{ .kind = .output, .index = 1, .node_id = double_graph.grappl_graph.entry_id orelse unreachable }, .{}, 0);
        const return_id = try app.NodeAdder.addNode("return", .{ .kind = .output, .index = 0, .node_id = 0 }, .{}, 0);
        try double_graph.addLiteralInput(mul_node_id, 1, 0, .{ .int = 2 });
        try double_graph.addEdge(a, mul_node_id, 0, return_id, 1, 0);
    }

    app.current_graph = main_graph;

    {
        // entry --> confetti --> double --------> return
        //           100          10   . --------> .
        const confetti_node_id = try app.NodeAdder.addNode("confetti", .{ .kind = .output, .index = 0, .node_id = 0 }, .{}, 0);
        try main_graph.addLiteralInput(confetti_node_id, 1, 0, .{ .int = 100 });
        const double_node_id = try app.NodeAdder.addNode("double", .{ .kind = .output, .index = 0, .node_id = confetti_node_id }, .{}, 0);
        try main_graph.addLiteralInput(double_node_id, 1, 0, .{ .int = 10 });
        const return_id = try app.NodeAdder.addNode("return", .{ .kind = .output, .index = 0, .node_id = double_node_id }, .{}, 0);
        try main_graph.addEdge(a, double_node_id, 1, return_id, 1, 0);
    }

    var combined = try app.combineGraphs();
    defer combined.deinit(gpa);

    errdefer std.debug.print("combined:\n{s}\n", .{combined});

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
    var diagnostic = grappl.compiler.Diagnostic.init();
    errdefer if (diagnostic.err != .None) std.debug.print("diagnostic: {}", .{diagnostic});

    const compiled = try grappl.compiler.compile(gpa, &combined, &app.shared_env, &app.user_funcs, &diagnostic);
    defer gpa.free(compiled);

    const expected = std.fmt.comptimePrint(
        \\({s}
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
        \\      (local $__lc0
        \\             i32)
        \\      (call $confetti
        \\            (i32.const 100))
        \\      (call $double
        \\            (i32.const 10))
        \\      (local.set $__lc0)
        \\      (local.get $__lc0))
        \\(export "double"
        \\        (func $double))
        \\(type $typeof_double
        \\      (func (param i32)
        \\            (result i32)))
        \\(func $double
        \\      (param $param_a1
        \\             i32)
        \\      (result i32)
        \\      (i32.mul (local.get $param_a1)
        \\               (i32.const 2)))
        \\)
    , .{grappl.compiler.compiled_prelude});

    try std.testing.expectEqualStrings(expected, compiled);

    try grappl.testing.expectWasmOutput(20, compiled, "main", .{});
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

//     errdefer std.debug.print("combined:\n{s}\n", .{combined});

//     try std.testing.expectFmt(file_content, "{}", .{combined});

//     // FIXME: use testing allocator
//     var diagnostic = grappl.compiler.Diagnostic.init();
//     errdefer if (diagnostic.err != .None) std.debug.print("diagnostic: {}", .{diagnostic});

//     const compiled = try grappl.compiler.compile(gpa, &combined, &app.shared_env, &app.user_funcs, &diagnostic);
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
//     , .{grappl.compiler.compiled_prelude});

//     try std.testing.expectEqualStrings(expected, compiled);
// }

test "sample1 (if)" {
    const a = std.testing.allocator;

    const confetti_func_id = try app._createUserFunc("confetti", 1, 0);
    try app._addUserFuncInput(confetti_func_id, 0, "particleCount", .i32_);

    defer app.deinit();
    try app.init();

    const main_graph = app.current_graph;

    {
        // entry --> if   then ----------------> return
        //           true else -.      + . ----> .
        //                       `     2
        //                       |     3
        //                       |
        //                       `--> return
        //                            1
        const if_node_id = try app.NodeAdder.addNode("if", .{ .kind = .output, .index = 0, .node_id = 0 }, .{}, 0);
        try main_graph.addLiteralInput(if_node_id, 1, 0, .{ .bool = true });
        const plus_node_id = try app.NodeAdder.addNode("+", .{ .kind = .output, .index = 0, .node_id = if_node_id }, .{}, 0);
        try main_graph.addLiteralInput(plus_node_id, 0, 0, .{ .int = 2 });
        try main_graph.addLiteralInput(plus_node_id, 1, 0, .{ .int = 3 });
        const return1_id = try app.NodeAdder.addNode("return", .{ .kind = .output, .index = 0, .node_id = if_node_id }, .{}, 0);
        try main_graph.addEdge(a, plus_node_id, 1, return1_id, 1, 0);
        const return2_id = try app.NodeAdder.addNode("return", .{ .kind = .output, .index = 1, .node_id = if_node_id }, .{}, 0);
        try main_graph.addLiteralInput(return2_id, 1, 0, .{ .int = 1 });
    }

    var combined = try app.combineGraphs();
    defer combined.deinit(gpa);

    errdefer std.debug.print("combined:\n{s}\n", .{combined});

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
    var diagnostic = grappl.compiler.Diagnostic.init();
    errdefer if (diagnostic.err != .None) std.debug.print("diagnostic: {}", .{diagnostic});

    const compiled = try grappl.compiler.compile(gpa, &combined, &app.shared_env, &app.user_funcs, &diagnostic);
    defer gpa.free(compiled);

    const expected = std.fmt.comptimePrint(
        \\({s}
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
        \\      (param $param_n
        \\             i32)
        \\      (result i32)
        \\      (if (result i32)
        \\          (i32.le_s (local.get $param_n)
        \\                    (i32.const 1))
        \\          (then (i32.const 1))
        \\          (else (i32.mul (local.get $param_n)
        \\                         (call $factorial
        \\                               (i32.sub (local.get $param_n)
        \\                                        (i32.const 1)))))))
        \\)
    , .{grappl.compiler.compiled_prelude});

    try std.testing.expectEqualStrings(expected, compiled);

    try grappl.testing.expectWasmOutput(20, compiled, "main", .{});
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

// graphInitState={{
//   notRemovable: true,
//   nodes: [
//     {
//       id: 2,
//       type: "SELECT",
//       inputs: {
//         1: { string: "col1" },
//       },
//     },
//     {
//       id: 3,
//       type: "FROM",
//       inputs: {
//         0: { node: 2, outPin: 0 },
//         1: { string: "table" },
//       },
//     },
//     {
//       id: 4,
//       type: "make-symbol",
//       inputs: {
//         0: { string: "col1" },
//       },
//     },
//     {
//       id: 5,
//       type: "==",
//       inputs: {
//         0: { node: 4, outPin: 0 },
//         1: { int: 2 },
//       },
//     },
//     {
//       id: 6,
//       type: "WHERE",
//       inputs: {
//         0: { node: 3, outPin: 0 },
//         1: { node: 5, outPin: 0 },
//       },
//     },
//     {
//       id: 1,
//       type: "query-string",
//       inputs: {
//         0: { node: 0, outPin: 0 },
//         1: { node: 6, outPin: 0 },
//       },
//     },
//   ],
// }}
