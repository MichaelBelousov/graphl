const std = @import("std");
const builtin = @import("builtin");

// TODO: deprecate this export
pub const GraphTypes = @import("./nodes/builtin.zig").GraphTypes;

// FIXME: use tail!
// NOTE: .always_tail is not fully implemented (won't throw an error)
//pub const debug_tail_call = if (builtin.mode == .Debug) .never_inline else .always_tail;
pub const debug_tail_call: std.builtin.CallModifier = if (builtin.mode == .Debug) .never_inline else .auto;

var global_allocator_inst = switch (builtin.target.os.tag) {
    .wasi, .freestanding => std.heap.WasmAllocator{},
    // FIXME: use c allocator in the future, it's decently more performant
    .linux, .macos, .windows => std.heap.GeneralPurposeAllocator(.{}){},
    else => @compileError("unsupported architecture"),
};

pub const global_alloc = switch (builtin.target.os.tag) {
    .wasi, .freestanding => std.heap.wasm_allocator,
    .linux, .macos, .windows => global_allocator_inst.allocator(),
    else => @compileError("unsupported architecture"),
};
