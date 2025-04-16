const std = @import("std");

const graphl = @import("graphl");

pub fn compileSource(a: std.mem.Allocator, file_name: []const u8, src: []const u8) ![]const u8 {
    _ = file_name; // FIXME

    var parse_diag = graphl.SexpParser.Diagnostic{ .source = src };
    defer if (parse_diag.result != .none) {
        std.debug.print("diag={}", .{parse_diag});
    };
    var parsed = try graphl.SexpParser.parse(a, src, &parse_diag);
    defer parsed.deinit();

    var diagnostic = graphl.compiler.Diagnostic.init();

    return graphl.compiler.compile(a, &parsed.module, null, &diagnostic);
}
