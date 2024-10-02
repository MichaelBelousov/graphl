const std = @import("std");
const builtin = @import("builtin");

pub const ExtraIndex = struct { index: usize };

pub const GraphTypes = @import("./nodes/builtin.zig").GraphTypes(ExtraIndex);

// NOTE: .always_tail is not fully implemented (won't throw an error)
pub const debug_tail_call = if (builtin.mode == .Debug) .never_inline else .always_tail;

pub const global_alloc = std.heap.wasm_allocator;
