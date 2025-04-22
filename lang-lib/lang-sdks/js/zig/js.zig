const std = @import("std");

const graphl = @import("graphl");

pub const Diagnostic = struct {
    @"error": []const u8 = "",
};

pub fn compileSource(
    a: std.mem.Allocator,
    file_name: []const u8,
    src: []const u8,
    out_diag_ptr: ?*Diagnostic,
) ![]const u8 {
    _ = file_name; // FIXME

    var parse_diag = graphl.SexpParser.Diagnostic{ .source = src };
    var parsed = graphl.SexpParser.parse(a, src, &parse_diag) catch |err| {
        if (out_diag_ptr) |out_diag| {
            out_diag.@"error" = try std.fmt.allocPrint(a, "{}", .{parse_diag});
        }
        return err;
    };
    defer parsed.deinit();

    var diagnostic = graphl.compiler.Diagnostic.init();

    return graphl.compiler.compile(a, &parsed.module, null, &diagnostic) catch |err| {
        if (out_diag_ptr) |out_diag| {
            out_diag.@"error" = try std.fmt.allocPrint(a, "{}", .{diagnostic});
        }
        return err;
    };
}
