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

const compiler = @import("./compiler-wasm.zig");
const compile = @import("./compiler-wasm.zig").compile;
const compiled_prelude = @import("./compiler-wasm.zig").compiled_prelude;
const Diagnostic = @import("./compiler-wasm.zig").Diagnostic;
const expectWasmEqualsWat = @import("./compiler-wasm.zig").expectWasmEqualsWat;

test "compare double and int" {
    var parsed = try SexpParser.parse(t.allocator,
        \\;;; comment ;; TODO: reintroduce use of a parameter
        \\(typeof (cmp-dbl) bool)
        \\(define (cmp-dbl)
        \\  (begin
        \\    (return (>= 5.0 2))))
        \\
    , null);
    defer parsed.deinit();

    const expected =
        \\(module
        \\  (type (;0;) (func (result i32)))
        \\  (type (;1;) (func (param i32) (result f64)))
        \\  (memory (;0;) 1 256)
        \\  (export "memory" (memory 0))
        \\  (export "cmp-dbl" (func $cmp-dbl))
        \\  (func $cmp-dbl (;0;) (type 0) (result i32)
        \\    (local i32 i32 i32 i32 i32 f64)
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      f64.const 0x1.4p+2 (;=5;)
        \\      local.set 5
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        block ;; label = @3
        \\          i32.const 2
        \\          local.set 4
        \\          local.get 5
        \\          local.get 4
        \\          i64.extend_i32_s
        \\          f32.convert_i64_s
        \\          f64.promote_f32
        \\          f64.ge
        \\          local.set 3
        \\        end
        \\        local.get 3
        \\        return
        \\      end
        \\      unreachable
        \\    end
        \\    unreachable
        \\  )
        \\  (func $Vec3->X (;1;) (type 1) (param i32) (result f64)
        \\    local.get 0
        \\    f64.load
        \\  )
        \\  (@custom "sourceMappingURL" (after code) "\07/script")
        \\)
        \\
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed.module, null, &diagnostic)) |wasm| {
        defer t.allocator.free(wasm);
        try expectWasmEqualsWat(expected, wasm);
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
    defer parsed.deinit();

    const expected =
        \\(module
        \\  (type (;0;) (func (result i32)))
        \\  (type (;1;) (func (param i32) (result f64)))
        \\  (memory (;0;) 1 256)
        \\  (export "memory" (memory 0))
        \\  (export "cmp-int" (func $cmp-int))
        \\  (func $cmp-int (;0;) (type 0) (result i32)
        \\    (local i32 i32 i32 i32 i32 i32)
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      i32.const 0
        \\      local.set 4
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        block ;; label = @3
        \\          i32.const 0
        \\          local.set 5
        \\          local.get 4
        \\          local.get 5
        \\          i32.ne
        \\          local.set 3
        \\        end
        \\        local.get 3
        \\        return
        \\      end
        \\      unreachable
        \\    end
        \\    unreachable
        \\  )
        \\  (func $Vec3->X (;1;) (type 1) (param i32) (result f64)
        \\    local.get 0
        \\    f64.load
        \\  )
        \\  (@custom "sourceMappingURL" (after code) "\07/script")
        \\)
        \\
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed.module, null, &diagnostic)) |wasm| {
        defer t.allocator.free(wasm);
        try expectWasmEqualsWat(expected, wasm);
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
    defer parsed.deinit();

    const expected =
        \\(module
        \\  (type (;0;) (func (param i32) (result i32)))
        \\  (type (;1;) (func (param i32) (result f64)))
        \\  (memory (;0;) 1 256)
        \\  (export "memory" (memory 0))
        \\  (export "factorial" (func 0))
        \\  (func (;0;) (type 0) (param i32) (result i32)
        \\    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      local.get 0
        \\      local.set 5
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        i32.const 1
        \\        local.set 6
        \\        local.get 5
        \\        local.get 6
        \\        i32.le_s
        \\        local.set 4
        \\      end
        \\      local.get 4
        \\      if ;; label = @2
        \\        block ;; label = @3
        \\          block ;; label = @4
        \\            i32.const 1
        \\            local.set 9
        \\            local.get 9
        \\            return
        \\          end
        \\          unreachable
        \\        end
        \\      else
        \\        br 1 (;@1;)
        \\      end
        \\    end
        \\    block ;; label = @1
        \\      local.get 0
        \\      local.set 13
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      local.get 0
        \\      local.set 16
        \\      br 0 (;@1;)
        \\    end
        \\    i32.const 1
        \\    local.set 17
        \\    local.get 16
        \\    local.get 17
        \\    i32.sub
        \\    local.set 15
        \\    local.get 15
        \\    call 0
        \\    local.set 14
        \\    local.get 13
        \\    local.get 14
        \\    i32.mul
        \\    local.set 12
        \\    local.get 12
        \\    return
        \\  )
        \\  (func (;1;) (type 1) (param i32) (result f64)
        \\    local.get 0
        \\    f64.load
        \\  )
        \\  (@custom "sourceMappingURL" (after code) "\07/script")
        \\)
        \\
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed.module, null, &diagnostic)) |wasm| {
        defer t.allocator.free(wasm);
        try expectWasmEqualsWat(expected, wasm);
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}

test "simple string" {
    var parsed = try SexpParser.parse(t.allocator,
        \\(typeof (simple) string)
        \\(define (simple)
        \\        (return "hello"))
    , null);
    defer parsed.deinit();

    const expected =
        \\(module
        \\  (type (;0;) (array (mut i8)))
        \\  (type (;1;) (func (result (ref null 0))))
        \\  (type (;2;) (func (param (ref null 0))))
        \\  (memory (;0;) 1 256)
        \\  (export "memory" (memory 0))
        \\  (export "simple" (func $simple))
        \\  (export "__graphl_host_copy" (func $__graphl_host_copy))
        \\  (func $simple (;0;) (type 1) (result (ref null 0))
        \\    (local (ref null 0) (ref null 0) (ref null 0))
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    i32.const 0
        \\    i32.const 5
        \\    array.new_data 0 $s_5120
        \\    local.set 2
        \\    local.get 2
        \\    return
        \\  )
        \\  (func $__graphl_host_copy (;1;) (type 2) (param (ref null 0))
        \\    (local i32 i32)
        \\    local.get 0
        \\    array.len
        \\    local.set 1
        \\    loop ;; label = @1
        \\      i32.const 1024
        \\      local.get 2
        \\      i32.add
        \\      local.get 0
        \\      local.get 2
        \\      array.get_u 0
        \\      i32.store
        \\      local.get 2
        \\      i32.const 1
        \\      i32.add
        \\      local.set 2
        \\      local.get 2
        \\      local.get 1
        \\      i32.lt_u
        \\      br_if 0 (;@1;)
        \\    end
        \\  )
        \\  (data $str_transfer (;0;) "\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00")
        \\  (data $s_5120 (;1;) "hello")
        \\  (@custom "sourceMappingURL" (after data) "\07/script")
        \\)
        \\
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed.module, null, &diagnostic)) |wasm| {
        defer t.allocator.free(wasm);
        try expectWasmEqualsWat(expected, wasm);
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}

test "(u64,string) -> string ;; return literal" {
    var user_funcs = std.SinglyLinkedList(compiler.UserFunc){};

    const user_func_1 = try t.allocator.create(std.SinglyLinkedList(compiler.UserFunc).Node);
    user_func_1.* = std.SinglyLinkedList(compiler.UserFunc).Node{
        .data = .{
            .id = 0,
            .node = .{
                .name = "JavaScript-Eval",
                .inputs = try t.allocator.dupe(builtin.Pin, &.{
                    builtin.Pin{ .name = "exec", .kind = .{ .primitive = .exec } },
                    builtin.Pin{
                        .name = "ElementId",
                        .kind = .{ .primitive = .{ .value = primitive_types.u64_ } },
                    },
                    builtin.Pin{
                        .name = "code",
                        .kind = .{ .primitive = .{ .value = primitive_types.string } },
                    },
                }),
                // FIXME: why dupe these? why not just not free them and they're static?
                .outputs = try t.allocator.dupe(builtin.Pin, &.{
                    builtin.Pin{ .name = "out", .kind = .{ .primitive = .exec } },
                    builtin.Pin{
                        .name = "json-result",
                        .kind = .{ .primitive = .{ .value = primitive_types.string } },
                    },
                }),
            },
        },
    };
    defer t.allocator.destroy(user_func_1);
    defer t.allocator.free(user_func_1.data.node.inputs);
    defer t.allocator.free(user_func_1.data.node.outputs);
    user_funcs.prepend(user_func_1);

    var parsed = try SexpParser.parse(t.allocator,
        \\(import JavaScript-Eval "host/JavaScript-Eval")
        \\(typeof (processInstance u64
        \\                         vec3
        \\                         vec3)
        \\        string)
        \\(define (processInstance MeshId
        \\                         Origin
        \\                         Rotation)
        \\        (begin (JavaScript-Eval MeshId
        \\                                "console.log(\"hello\"); 5")
        \\               (return "imodel")))
    , null);
    //std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit();

    const expected =
        \\(module
        \\  (type (;0;) (array (mut i8)))
        \\  (type (;1;) (func (param i32) (result f64)))
        \\  (type (;2;) (struct (field (mut f64)) (field (mut f64)) (field (mut f64))))
        \\  (type (;3;) (func (param i64 (ref null 0)) (result (ref null 0))))
        \\  (type (;4;) (func (param i64 (ref null 2) (ref null 2)) (result (ref null 0))))
        \\  (type (;5;) (func (param i32 i64 (ref null 0)) (result (ref null 0))))
        \\  (import "env" "callUserFunc_u64_string_R_string" (func (;0;) (type 5)))
        \\  (memory (;0;) 1 256)
        \\  (export "memory" (memory 0))
        \\  (export "processInstance" (func $processInstance))
        \\  (func $JavaScript-Eval (;1;) (type 3) (param i64 (ref null 0)) (result (ref null 0))
        \\    i32.const 0
        \\    local.get 0
        \\    local.get 1
        \\    call 0
        \\  )
        \\  (func $processInstance (;2;) (type 4) (param i64 (ref null 2) (ref null 2)) (result (ref null 0))
        \\    (local (ref null 0) (ref null 0) (ref null 0) (ref null 0) (ref null 0) (ref null 0) i64)
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      local.get 0
        \\      local.set 9
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        i32.const 1024
        \\        i32.const 23
        \\        array.new_data 0 0
        \\        local.set 6
        \\        local.get 9
        \\        local.get 6
        \\        call $JavaScript-Eval
        \\        local.set 5
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        i32.const 1047
        \\        i32.const 6
        \\        array.new_data 0 0
        \\        local.set 8
        \\        local.get 8
        \\        return
        \\      end
        \\      unreachable
        \\    end
        \\    unreachable
        \\  )
        \\  (func $Vec3->X (;3;) (type 1) (param i32) (result f64)
        \\    local.get 0
        \\    f64.load
        \\  )
        \\  (func $Vec3->Y (;4;) (type 1) (param i32) (result f64)
        \\    local.get 0
        \\    f64.load offset=8
        \\  )
        \\  (func $Vec3->Z (;5;) (type 1) (param i32) (result f64)
        \\    local.get 0
        \\    f64.load offset=16
        \\  )
        \\  (data (;0;) (i32.const 1024) "console.log(\22hello\22); 5")
        \\  (data (;1;) (i32.const 1047) "imodel")
        \\  (@custom "sourceMappingURL" (after data) "\07/script")
        \\)
        \\
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed.module, &user_funcs, &diagnostic)) |wasm| {
        defer t.allocator.free(wasm);
        try expectWasmEqualsWat(expected, wasm);
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}

test "(u64,string) -> string ;; labeled return" {
    var user_funcs = std.SinglyLinkedList(compiler.UserFunc){};

    const user_func_1 = try t.allocator.create(std.SinglyLinkedList(compiler.UserFunc).Node);
    user_func_1.* = std.SinglyLinkedList(compiler.UserFunc).Node{
        .data = .{
            .id = 0,
            .node = .{
                .name = "JavaScript-Eval",
                .inputs = try t.allocator.dupe(builtin.Pin, &.{
                    builtin.Pin{ .name = "exec", .kind = .{ .primitive = .exec } },
                    builtin.Pin{
                        .name = "ElementId",
                        .kind = .{ .primitive = .{ .value = primitive_types.u64_ } },
                    },
                    builtin.Pin{
                        .name = "code",
                        .kind = .{ .primitive = .{ .value = primitive_types.string } },
                    },
                }),
                // FIXME: why dupe these? why not just not free them and they're static?
                .outputs = try t.allocator.dupe(builtin.Pin, &.{
                    builtin.Pin{ .name = "out", .kind = .{ .primitive = .exec } },
                    builtin.Pin{
                        .name = "json-result",
                        .kind = .{ .primitive = .{ .value = primitive_types.string } },
                    },
                }),
            },
        },
    };
    defer t.allocator.destroy(user_func_1);
    defer t.allocator.free(user_func_1.data.node.inputs);
    defer t.allocator.free(user_func_1.data.node.outputs);
    user_funcs.prepend(user_func_1);

    var env = try Env.initDefault(t.allocator);
    defer env.deinit(t.allocator);

    {
        var maybe_cursor = user_funcs.first;
        while (maybe_cursor) |cursor| : (maybe_cursor = cursor.next) {
            _ = try env.addNode(t.allocator, builtin.basicMutableNode(&cursor.data.node));
        }
    }

    var parsed = try SexpParser.parse(t.allocator,
        \\(typeof (processInstance u64
        \\                         vec3
        \\                         vec3)
        \\        string)
        \\(define (processInstance MeshId
        \\                         Origin
        \\                         Rotation)
        \\        (begin (JavaScript-Eval MeshId
        \\                                "console.log(\"hello\"); 5") #!__label1
        \\               (return __label1)))
    , null);
    //std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit();

    // imports could be in arbitrary order so just slice it off cuz length will
    // be the same
    const expected_prelude =
        \\(module
        \\(import "env"
        \\        "callUserFunc_u64_string_R_string"
        \\        (func $callUserFunc_u64_string_R_string
        \\              (param i32)
        \\              (param i64)
        \\              (param i32)
        \\              (result i32)))
        \\(global $__grappl_vstkp
        \\        (mut i32)
        \\        (i32.const 4096))
        \\
    ++ compiled_prelude ++
        \\
        \\
    ;

    const expected =
        \\(func $JavaScript-Eval
        \\      (param $param_0
        \\             i64)
        \\      (param $param_1
        \\             i32)
        \\      (result i32)
        \\      (call $callUserFunc_u64_string_R_string
        \\            (i32.const 0)
        \\            (local.get $param_0)
        \\            (local.get $param_1)))
        \\(export "processInstance"
        \\        (func $processInstance))
        \\(type $typeof_processInstance
        \\      (func (param i64)
        \\            (param i32)
        \\            (param i32)
        \\            (result i32)))
        \\(func $processInstance
        \\      (param $param_MeshId
        \\             i64)
        \\      (param $param_Origin
        \\             i32)
        \\      (param $param_Rotation
        \\             i32)
        \\      (result i32)
        \\      (local $__frame_start
        \\             i32)
        \\      (local $__lc0
        \\             i32)
        \\      (local $__lc1
        \\             i32)
        \\      (local.set $__frame_start
        \\                 (i32.add (global.get $__grappl_vstkp)
        \\                          (i32.const 8)))
        \\      (i32.store (global.get $__grappl_vstkp)
        \\                 (i32.const 23))
        \\      (i32.store (i32.add (global.get $__grappl_vstkp)
        \\                          (i32.const 4))
        \\                 (i32.const 4))
        \\      (local.set $__lc0
        \\                 (global.get $__grappl_vstkp))
        \\      (global.set $__grappl_vstkp
        \\                  (i32.add (global.get $__grappl_vstkp)
        \\                           (i32.const 8)))
        \\      (call $JavaScript-Eval
        \\            (local.get $param_MeshId)
        \\            (local.get $__lc0))
        \\      (local.set $__lc1)
        \\      (local.get $__lc1)
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\(data (i32.const 0)
        \\      "\17\00\00\00console.log(\22hello\22); 5")
        \\)
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &env, &user_funcs, &diagnostic)) |wat| {
        defer t.allocator.free(wat);
        {
            errdefer std.debug.print("======== prologue: =========\n{s}\n", .{wat[0 .. expected_prelude.len - compiled_prelude.len]});
            try t.expectEqualStrings(expected_prelude[0 .. expected_prelude.len - compiled_prelude.len], wat[0 .. expected_prelude.len - compiled_prelude.len]);
        }
        try t.expectEqualStrings(expected, wat[expected_prelude.len..]);
        // FIXME:
        // try expectWasmOutput(0, wat, "processInstance", .{
        //     0,
        //     0,
        //     0,
        // });
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}
