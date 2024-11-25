const std = @import("std");
const FileBuffer = @import("./FileBuffer.zig");
const compiler = @import("./compiler-wat.zig");
const Env = @import("./nodes/builtin.zig").Env;
const SexpParser = @import("./sexp_parser.zig").Parser;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var args = std.process.args();

    const program_name = args.next() orelse unreachable;
    _ = program_name;

    var env = try Env.initDefault(alloc);
    defer env.deinit(alloc);

    while (args.next()) |arg| {
        var fb = try FileBuffer.fromDirAndPath(alloc, std.fs.cwd(), arg);
        defer fb.free(alloc);

        var parse_diag = SexpParser.Diagnostic{ .source = fb.buffer };
        const parsed = SexpParser.parse(alloc, fb.buffer, &parse_diag) catch |parse_err| {
            std.debug.print("Parse error {} in '{s}':\n{}\n", .{ parse_err, arg, parse_diag });
            continue;
        };

        defer parsed.deinit(alloc);

        var compile_diag = compiler.Diagnostic.init();
        const wat = compiler.compile(alloc, &parsed, &env, null, &compile_diag) catch |compile_err| {
            std.debug.print("Compile error {} in '{s}':\n{}\n", .{ compile_err, arg, parse_diag });
            continue;
        };
        defer alloc.free(wat);

        // TODO: invoke wat2wasm
        std.debug.print("{s}", .{wat});
    }
}
