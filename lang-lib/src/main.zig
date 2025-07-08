const std = @import("std");
const builtin = @import("builtin");
const build_opts = @import("build_opts");

// FIXME: remove old garbage
// import to export these public functions

pub const IntArrayHashMap = @import("./json_int_map.zig").IntArrayHashMap;
pub const GraphBuilder = @import("./graph_to_source.zig").GraphBuilder;
pub const NodeId = @import("./graph_to_source.zig").NodeId;
const IndexedNode = @import("./common.zig").GraphTypes.Node;
pub const Node = @import("./common.zig").GraphTypes.Node;
pub const Link = @import("./common.zig").GraphTypes.Link;
pub const Env = @import("./nodes/builtin.zig").Env;
pub const Point = @import("./nodes/builtin.zig").Point;
pub const Pin = @import("./nodes/builtin.zig").Pin;
pub const PrimitivePin = @import("./nodes/builtin.zig").PrimitivePin;
pub const primitive_types = @import("./nodes/builtin.zig").primitive_types;
pub const nonprimitive_types = @import("./nodes/builtin.zig").nonprimitive_types;
pub const Type = @import("./nodes/builtin.zig").Type;
pub const TypeInfo = @import("./nodes/builtin.zig").TypeInfo;
pub const NodeDesc = @import("./nodes/builtin.zig").NodeDesc;
pub const BasicNodeDesc = @import("./nodes/builtin.zig").BasicNodeDesc;
pub const helpers = @import("./nodes/builtin.zig");
pub const Value = @import("./nodes/builtin.zig").Value;
pub const Sexp = @import("./sexp.zig").Sexp;
pub const ModuleContext = @import("./sexp.zig").ModuleContext;
pub const syms = @import("./sexp.zig").syms;
pub const SexpParser = @import("./sexp_parser.zig").Parser;
pub const intern_pool = @import("./InternPool.zig");

// FIXME: use @deprecated
pub const compiler = if (build_opts.disable_compiler) 
    @import("./compiler-types.zig")
else @import("./compiler-wasm.zig");

pub const std_options: std.Options = .{
    .log_level = if (builtin.is_test) .debug else std.log.default_level,
    .logFn = std.log.defaultLog,
};

pub const testing = struct {
    pub const expectWasmOutput = compiler.expectWasmOutput;
};

test {
    _ = @import("binaryen");
    // FIXME:
    std.testing.refAllDeclsRecursive(compiler);
    // std.testing.refAllDeclsRecursive(compiler_wasm);
    // std.testing.refAllDeclsRecursive(@import("./graph_to_source.zig"));
    //std.testing.refAllDeclsRecursive(@import("./sexp_parser.zig"));
    //std.testing.refAllDeclsRecursive(@This());
}

pub const SimpleDiagnostic = struct {
    @"error": []const u8 = "",
};


// TODO: move to own spot?
/// compile source using json to transmit the host environment
/// TODO: also offer a C API to build the host environment through function calls
pub fn simpleCompileSource(
    a: std.mem.Allocator,
    file_name: []const u8,
    src: []const u8,
    user_func_json: []const u8,
    out_diag_ptr: ?*SimpleDiagnostic,
) ![]const u8 {
    _ = file_name; // FIXME

    var parse_diag = SexpParser.Diagnostic{ .source = src };
    var parsed = SexpParser.parse(a, src, &parse_diag) catch |err| {
        if (out_diag_ptr) |out_diag| {
            out_diag.@"error" = try std.fmt.allocPrint(a, "{}", .{parse_diag});
        }
        return err;
    };
    defer parsed.deinit();

    var diagnostic = compiler.Diagnostic.init();

    var user_funcs = _: {
        var user_funcs = std.SinglyLinkedList(compiler.UserFunc){};

        var json_arena = std.heap.ArenaAllocator.init(a);
        defer json_arena.deinit();

        var json_diagnostics = std.json.Diagnostics{};
        var json_scanner = std.json.Scanner.initCompleteInput(a, user_func_json);
        json_scanner.enableDiagnostics(&json_diagnostics);
        const user_funcs_parsed = std.json.parseFromTokenSource(std.json.ArrayHashMap(compiler.UserFunc), a, &json_scanner, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.err("json parsing err: {}", .{err});
            std.log.err("byte={}, diagnostic={}", .{ json_diagnostics.getByteOffset(), json_diagnostics });
            return err;
        };
        // FIXME: this causes a leak that can't be fixed
        // do not deallocate on success so we can keep pointers into the json
        errdefer json_scanner.deinit();

        var entry_iter = user_funcs_parsed.value.map.iterator();
        while (entry_iter.next()) |entry| {
            const new_node = try a.create(std.SinglyLinkedList(compiler.UserFunc).Node);

            new_node.* = .{
                .data = .{
                    .id = entry.value_ptr.id,
                    .node = entry.value_ptr.node,
                    .@"async" = entry.value_ptr.@"async",
                },
            };

            user_funcs.prepend(new_node);
        }

        break :_ user_funcs;
    };

    return compiler.compile(a, &parsed.module, &user_funcs, &diagnostic) catch |err| {
        if (out_diag_ptr) |out_diag| {
            out_diag.@"error" = try std.fmt.allocPrint(a, "{}", .{diagnostic});
        }
        return err;
    };
}
