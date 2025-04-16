const std = @import("std");

const graphl = @import("graphl");

pub fn compileCode(file_name: []const u8, src: []const u8, diagnostics: ?graphl.compiler.Diagnostic) []const u8 {
    _ = file_name; // FIXME
    return "";
}
