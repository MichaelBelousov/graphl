const std = @import("std");
const Parser = @import("./sexp_parser.zig").Parser;
const FileBuffer = @import("./FileBuffer.zig");

pub fn main() !void {
    var args_iter = std.process.args();
    while (args_iter.next()) |arg| {
        const file = try FileBuffer.fromDirAndPath(std.heap.page_allocator, std.fs.cwd(), arg);
        defer file.free(std.heap.page_allocator);
        const parse_result = Parser.parse(std.heap.page_allocator, file.buffer);
        std.debug.print("parsed: {any}\n", .{parse_result});
    }
}
