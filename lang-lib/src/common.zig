const std = @import("std");
const builtin = @import("builtin");

pub const ExtraIndex = struct { index: usize };

pub const GraphTypes = @import("./nodes/builtin.zig").GraphTypes(ExtraIndex);

// NOTE: .always_tail is not fully implemented (won't throw an error)
pub const debug_tail_call = if (builtin.mode == .Debug) .never_inline else .always_tail;

var global_allocator_inst = switch (builtin.target.os.tag) {
    .wasi, .freestanding => std.heap.WasmAllocator{},
    .linux, .macos, .windows => std.heap.GeneralPurposeAllocator,
    else => @compileError("unsupported architecture"),
};

pub const global_alloc = switch (builtin.target.os.tag) {
    .wasi, .freestanding => std.heap.wasm_allocator,
    .linux, .macos, .windows => global_alloc.allocator(),
    else => @compileError("unsupported architecture"),
};
