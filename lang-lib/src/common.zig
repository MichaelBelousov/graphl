const std = @import("std");
const builtin = @import("builtin");

pub const ExtraIndex = struct {
    index: usize
};

pub const GraphTypes = @import("./nodes/builtin.zig").GraphTypes(ExtraIndex);

// NOTE: .always_tail is not fully implemented (won't throw an error)
pub const debug_tail_call = if (builtin.mode == .Debug) .never_inline else .always_tail;

// FIXME use std.heap.wasm_allocator
var result_buffer: [std.mem.page_size * 512]u8 = undefined;
var global_allocator_inst = std.heap.FixedBufferAllocator.init(&result_buffer);
pub const global_alloc = global_allocator_inst.allocator();

