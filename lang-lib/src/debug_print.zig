//! debug print implementation that works on wasm freestanding

const std = @import("std");
const builtin = @import("builtin");

// TODO: make optional
// in freestanding environment, an imported function that allows printing to the console
extern fn _wasm_debug_print(str: [*]const u8, len: usize) void;

pub fn debug_print(comptime fmt_str: []const u8, fmt_args: anytype) void {
    switch (builtin.target.os.tag) {
        // NOTE: a more sophisticated implementation would create a writer around _wasm_debug_print and
        .freestanding => {
            if (fmt_str.len > 3072)
                @compileError("format string too long");

            // NOTE: clip long strings in fmt_args to fit into the buf
            var buf: [4096]u8 = undefined;
            const printed = std.fmt.bufPrint(&buf, fmt_str, fmt_args) catch |e| std.debug.panic("Print too long ({})", .{e});
            _wasm_debug_print(printed.ptr, printed.len);
        },
        .wasi, .linux, .macos, .windows => {
            std.debug.print(fmt_str, fmt_args);
        },
        else => @compileError("unsupported architecture"),
    }
}
