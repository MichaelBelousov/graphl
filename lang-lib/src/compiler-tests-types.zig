//!
//! NOTE:
//! - probably would be better long term to use binaryen directly, it will have
//!   a more performant in-memory IR
//! - functions starting with ";" will cause a multiline comment, which is an example
//!   of small problems with this code not conforming to WAT precisely
//!

const zig_builtin = @import("builtin");
const build_opts = @import("build_opts");
const std = @import("std");
const t = std.testing;
const json = std.json;
const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;
const primitive_type_syms = @import("./sexp.zig").primitive_type_syms;
const builtin = @import("./nodes/builtin.zig");
const primitive_types = @import("./nodes/builtin.zig").primitive_types;
const Env = @import("./nodes//builtin.zig").Env;
const TypeInfo = @import("./nodes//builtin.zig").TypeInfo;
const Type = @import("./nodes/builtin.zig").Type;
const SexpParser = @import("./sexp_parser.zig").Parser;

// FIXME: use intrinsics as the base and merge/link in our functions
const compile = @import("./compiler-wat.zig").compile;
const compiled_prelude = @import("./compiler-wat.zig").compiled_prelude;
const Diagnostic = @import("./compiler-wat.zig").Diagnostic;
const expectWasmOutput = @import("./compiler-wat.zig").expectWasmOutput;

test "compare double and int" {
    var env = try Env.initDefault(t.allocator);
    defer env.deinit(t.allocator);

    var parsed = try SexpParser.parse(t.allocator,
        \\;;; comment ;; TODO: reintroduce use of a parameter
        \\(typeof (cmp-dbl) bool)
        \\(define (cmp-dbl)
        \\  (begin
        \\    (return (>= 5.0 2))))
        \\
    , null);
    //std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit(t.allocator);

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
        \\(export "cmp-dbl"
        \\        (func $cmp-dbl))
        \\(type $typeof_cmp-dbl
        \\      (func (result i32)))
        \\(func $cmp-dbl
        \\      (result i32)
        \\      (local $__frame_start
        \\             i32)
        \\      (local.set $__frame_start
        \\                 (global.get $__grappl_vstkp))
        \\      (f64.ge (f64.const 5)
        \\              (f64.promote_f32 (f32.convert_i64_s (i64.extend_i32_s (i32.const 2)))))
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\)
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &env, null, &diagnostic)) |wat| {
        defer t.allocator.free(wat);
        {
            errdefer std.debug.print("======== prologue: =========\n{s}\n", .{wat[0 .. expected_prelude.len - compiled_prelude.len]});
            try t.expectEqualStrings(expected_prelude, wat[0..expected_prelude.len]);
        }
        try t.expectEqualStrings(expected, wat[expected_prelude.len..]);
        // TODO: add parameter so we can cover the intrinsics behavior
        try expectWasmOutput(1, wat, "cmp-dbl", .{});
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}

test "compare int and int" {
    var env = try Env.initDefault(t.allocator);
    defer env.deinit(t.allocator);

    var parsed = try SexpParser.parse(t.allocator,
        \\;;; comment ;; TODO: reintroduce use of a parameter
        \\(typeof (cmp-int) bool)
        \\(define (cmp-int)
        \\  (begin
        \\    (return (!= 0 0))))
        \\
    , null);
    //std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit(t.allocator);

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
        \\(export "cmp-int"
        \\        (func $cmp-int))
        \\(type $typeof_cmp-int
        \\      (func (result i32)))
        \\(func $cmp-int
        \\      (result i32)
        \\      (local $__frame_start
        \\             i32)
        \\      (local.set $__frame_start
        \\                 (global.get $__grappl_vstkp))
        \\      (i32.ne (i32.const 0)
        \\              (i32.const 0))
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\)
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &env, null, &diagnostic)) |wat| {
        defer t.allocator.free(wat);
        {
            errdefer std.debug.print("======== prologue: =========\n{s}\n", .{wat[0 .. expected_prelude.len - compiled_prelude.len]});
            try t.expectEqualStrings(expected_prelude, wat[0..expected_prelude.len]);
        }
        try t.expectEqualStrings(expected, wat[expected_prelude.len..]);
        // TODO: add parameter so we can cover the intrinsics behavior
        try expectWasmOutput(0, wat, "cmp-int", .{});
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}

test "compare with call" {
    var env = try Env.initDefault(t.allocator);
    defer env.deinit(t.allocator);

    var parsed = try SexpParser.parse(t.allocator,
        \\(typeof (main)
        \\        i32)
        \\(define (main)
        \\        (begin (return (<= 4
        \\                            (Vec3->Y (Make-Vec3 0
        \\                                                3
        \\                                                10))))))
    , null);
    //std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit(t.allocator);

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
        \\      (local.set $__frame_start
        \\                 (global.get $__grappl_vstkp))
        \\      (f64.le (f64.promote_f32 (f32.convert_i64_s (i64.extend_i32_s (i32.const 4))))
        \\              (call $__grappl_vec3_y
        \\                    (call $__grappl_make_vec3
        \\                          (f64.promote_f32 (f32.convert_i64_s (i64.extend_i32_s (i32.const 0))))
        \\                          (f64.promote_f32 (f32.convert_i64_s (i64.extend_i32_s (i32.const 3))))
        \\                          (f64.promote_f32 (f32.convert_i64_s (i64.extend_i32_s (i32.const 10)))))))
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\)
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &env, null, &diagnostic)) |wat| {
        defer t.allocator.free(wat);
        {
            errdefer std.debug.print("======== prologue: =========\n{s}\n", .{wat[0 .. expected_prelude.len - compiled_prelude.len]});
            try t.expectEqualStrings(expected_prelude, wat[0..expected_prelude.len]);
        }
        try t.expectEqualStrings(expected, wat[expected_prelude.len..]);
        // TODO: add parameter so we can cover the intrinsics behavior
        try expectWasmOutput(0, wat, "main", .{});
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}
