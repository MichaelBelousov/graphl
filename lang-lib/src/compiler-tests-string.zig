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
const intrinsics = @import("./intrinsics.zig");
const intrinsics_raw = @embedFile("grappl_intrinsics");
const intrinsics_code = intrinsics_raw["(module $grappl_intrinsics.wasm\n".len .. intrinsics_raw.len - 2];
const compile = @import("./compiler-wat.zig").compile;
const compiled_prelude = @import("./compiler-wat.zig").compiled_prelude;
const Diagnostic = @import("./compiler-wat.zig").Diagnostic;

test "compile strings" {
    var env = try Env.initDefault(t.allocator);
    defer env.deinit(t.allocator);

    var parsed = try SexpParser.parse(t.allocator,
        \\;;; comment ;; TODO: reintroduce use of a parameter
        \\(typeof (strings-stuff) bool)
        \\(define (strings-stuff)
        \\  (begin
        \\    (return (String-Equal "hello" "world"))))
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
        \\(export "strings-stuff"
        \\        (func $strings-stuff))
        \\(type $typeof_strings-stuff
        \\      (func (result i32)))
        \\(func $strings-stuff
        \\      (result i32)
        \\      (local $__lc0
        \\             i32)
        \\      (local $__lc1
        \\             i32)
        \\      (i32.store (global.get $__grappl_vstkp)
        \\                 (i32.const 5))
        \\      (i32.store (i32.add (global.get $__grappl_vstkp)
        \\                          (i32.const 8))
        \\                 (i32.const 131))
        \\      (local.set $__lc0
        \\                 (global.get $__grappl_vstkp))
        \\      (global.set $__grappl_vstkp
        \\                  (i32.add (global.get $__grappl_vstkp)
        \\                           (i32.const 16)))
        \\      (i32.store (global.get $__grappl_vstkp)
        \\                 (i32.const 5))
        \\      (i32.store (i32.add (global.get $__grappl_vstkp)
        \\                          (i32.const 8))
        \\                 (i32.const 160))
        \\      (local.set $__lc1
        \\                 (global.get $__grappl_vstkp))
        \\      (global.set $__grappl_vstkp
        \\                  (i32.add (global.get $__grappl_vstkp)
        \\                           (i32.const 16)))
        \\      (call $__grappl_string_equal
        \\            (local.get $__lc0)
        \\            (local.get $__lc1)))
        \\(data (i32.const 123)
        \\      "\05\00\00\00\00\00\00\00hello")
        \\(data (i32.const 152)
        \\      "\05\00\00\00\00\00\00\00world")
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
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}
