const std = @import("std");
const builtin = @import("builtin");
const build_opts = @import("build_opts");

// FIXME: remove old garbage
// import to export these public functions

pub const IntArrayHashMap = @import("./json_int_map.zig").IntArrayHashMap;
pub const GraphBuilder = @import("./graph_to_source.zig").GraphBuilder;
pub const NodeId = @import("./graph_to_source.zig").NodeId;
const IndexedNode = @import("./common.zig").GraphTypes.Node;
pub const Node = @import("./common.zig").GraphTypes.Node;
pub const Link = @import("./common.zig").GraphTypes.Link;
pub const Env = @import("./nodes/builtin.zig").Env;
pub const Point = @import("./nodes/builtin.zig").Point;
pub const Pin = @import("./nodes/builtin.zig").Pin;
pub const PrimitivePin = @import("./nodes/builtin.zig").PrimitivePin;
pub const primitive_types = @import("./nodes/builtin.zig").primitive_types;
pub const Type = @import("./nodes/builtin.zig").Type;
pub const TypeInfo = @import("./nodes/builtin.zig").TypeInfo;
pub const NodeDesc = @import("./nodes/builtin.zig").NodeDesc;
pub const BasicNodeDesc = @import("./nodes/builtin.zig").BasicNodeDesc;
pub const helpers = @import("./nodes/builtin.zig");
pub const Value = @import("./nodes/builtin.zig").Value;
pub const Sexp = @import("./sexp.zig").Sexp;
pub const ModuleContext = @import("./sexp.zig").ModuleContext;
pub const syms = @import("./sexp.zig").syms;
pub const SexpParser = @import("./sexp_parser.zig").Parser;
pub const intern_pool = @import("./InternPool.zig");

// FIXME: use @deprecated
pub const compiler = if (build_opts.disable_compiler) 
    @import("./compiler-types.zig")
else @import("./compiler-wasm.zig");

pub const std_options: std.Options = .{
    .log_level = if (builtin.is_test) .debug else std.log.default_level,
    .logFn = std.log.defaultLog,
};

pub const testing = struct {
    pub const expectWasmOutput = compiler.expectWasmOutput;
};

pub fn _wasm_init() callconv(.C) void {
    intern_pool._intern_pool_constructor();
    if (!build_opts.disable_compiler) 
        compiler._binaryen_helper_constructor();
}

comptime {
    if (builtin.cpu.arch.isWasm()) {
        @export(&_wasm_init, .{ .name = "_wasm_init" });
    }
}

test {
    _ = @import("binaryen");
    // FIXME:
    std.testing.refAllDeclsRecursive(compiler);
    // std.testing.refAllDeclsRecursive(compiler_wasm);
    // std.testing.refAllDeclsRecursive(@import("./graph_to_source.zig"));
    //std.testing.refAllDeclsRecursive(@import("./sexp_parser.zig"));
    //std.testing.refAllDeclsRecursive(@This());
}
