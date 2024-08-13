const std = @import("std");
const builtin = @import("builtin");
const FileBuffer = @import("./FileBuffer.zig");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const io = std.io;
const testing = std.testing;

const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;
const ide_json_gen = @import("./ide_json_gen.zig");

const Result = @import("./result.zig").Result;
const Loc = @import("./loc.zig").Loc;

const Env = @import("./nodes/builtin.zig").Env;
const Value = @import("./nodes/builtin.zig").Value;

const GraphTypes = @import("./common.zig").GraphTypes;
const IndexedNode = GraphTypes.Node;
const IndexedLink = GraphTypes.Link;

const Slice = @import("./slice.zig").Slice;

const JsonNodeHandle = @import("./json_format.zig").JsonNodeHandle;
const JsonNodeInput = @import("./json_format.zig").JsonNodeInput;
const JsonNode = @import("./json_format.zig").JsonNode;
const Import = @import("./json_format.zig").Import;
const GraphDoc = @import("./json_format.zig").GraphDoc;

test "source_to_graph" {}

// FIXME use wasm known memory limits or something
var result_buffer: [std.mem.page_size * 512]u8 = undefined;
var global_allocator_inst = std.heap.FixedBufferAllocator.init(&result_buffer);
const global_alloc = global_allocator_inst.allocator();

/// call c free on result
export fn source_to_graph(source: Slice) Result(Slice) {
    _ = source;
    return Result(Slice).ok(Slice.fromZig(""));
}

// TODO: only export in wasi
pub fn main() void {}

// comptime {
//     if (builtin.target.cpu.arch == .wasm32) {
//         @export(alloc_string, .{ .name = "alloc_string", .linkage = .Strong });
//         @export(free_string, .{ .name = "free_string", .linkage = .Strong });
//     }
// }
