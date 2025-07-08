pub fn compileSource(
    a: std.mem.Allocator,
    file_name: []const u8,
    src: []const u8,
    user_func_json: []const u8,
    out_diag_ptr: ?*graphl.SimpleDiagnostic,
) ![]const u8 {
    return graphl.simpleCompileSource(a, file_name, src, user_func_json, out_diag_ptr) catch |err| {
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return err;
    };
}
const std = @import("std");
const graphl = @import("graphl");
