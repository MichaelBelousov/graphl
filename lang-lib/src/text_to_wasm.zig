const std = @import("std");
const FileBuffer = @import("./FileBuffer.zig");
const compiler = @import("./compiler-wat.zig");
const Env = @import("./nodes/builtin.zig").Env;
const helpers = @import("./nodes/builtin.zig");
const SexpParser = @import("./sexp_parser.zig").Parser;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    var args = std.process.args();

    const program_name = args.next() orelse unreachable;
    _ = program_name;

    var env = try Env.initDefault(alloc);
    defer env.deinit(alloc);

    var user_funcs = std.SinglyLinkedList(compiler.UserFunc){};
    var user_func_id: usize = 0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--env")) {
            const arg_val = args.next() orelse {
                std.debug.print("--env requires a value", .{});
                return error.EnvNoVal;
            };

            const lpar = std.mem.indexOf(u8, arg_val, "(") orelse {
                std.debug.print("--env requires a value with parens like 'node(i32)i32'", .{});
                return error.EnvNoLPar;
            };
            const rpar = std.mem.indexOf(u8, arg_val, ")") orelse {
                std.debug.print("--env requires a value with parens like 'node(i32)i32'", .{});
                return error.EnvNoRPar;
            };

            const func_name = arg_val[0..lpar];
            const params_src = arg_val[lpar + 1 .. rpar];
            // one extra for exec, one extra cuz no trailing comma
            const param_count = 2 + std.mem.count(u8, params_src, ",");
            var params_names_iter = std.mem.splitScalar(u8, params_src, ',');
            const params = try alloc.alloc(helpers.Pin, param_count);
            params[0] = helpers.Pin{
                .name = "a",
                .kind = .{ .primitive = .exec },
            };
            for (params[1..]) |*param| {
                const param_name = params_names_iter.next() orelse unreachable;
                param.* = helpers.Pin{
                    .name = "a",
                    .kind = .{
                        .primitive = .{
                            .value = env.getType(param_name) orelse std.debug.panic("type not found: '{s}'", .{param_name}),
                        },
                    },
                };
            }
            const return_type_name = arg_val[rpar + 1 ..];

            const outputs = try alloc.alloc(helpers.Pin, if (return_type_name.len > 0) 2 else 1);
            outputs[0] = helpers.Pin{
                .name = "done",
                .kind = .{ .primitive = .exec },
            };
            if (return_type_name.len > 0) {
                outputs[1] = helpers.Pin{
                    .name = "res",
                    .kind = .{
                        .primitive = .{
                            .value = env.getType(return_type_name) orelse std.debug.panic("type not found: '{s}'", .{return_type_name}),
                        },
                    },
                };
            }

            const user_func = try alloc.create(std.SinglyLinkedList(compiler.UserFunc).Node);
            user_func.* = .{ .data = .{
                .id = user_func_id,
                .node = helpers.BasicMutNodeDesc{
                    .name = func_name,
                    .inputs = params,
                    .outputs = outputs,
                },
            } };
            user_func_id += 1;
            user_funcs.prepend(user_func);

            _ = try env.addNode(alloc, helpers.basicMutableNode(&user_func.data.node));

            continue;
        }

        var fb = try FileBuffer.fromDirAndPath(alloc, std.fs.cwd(), arg);
        defer fb.free(alloc);

        var parse_diag = SexpParser.Diagnostic{ .source = fb.buffer };
        const parsed = SexpParser.parse(alloc, fb.buffer, &parse_diag) catch |parse_err| {
            std.debug.print("Parse error {} in '{s}':\n{}\n", .{ parse_err, arg, parse_diag });
            continue;
        };

        defer parsed.deinit(alloc);

        var compile_diag = compiler.Diagnostic.init();
        const wat = compiler.compile(alloc, &parsed, &env, &user_funcs, &compile_diag) catch |compile_err| {
            std.debug.print("Compile error {} in '{s}':\n{}\n", .{ compile_err, arg, parse_diag });
            continue;
        };
        defer alloc.free(wat);

        // TODO: invoke wat2wasm
        var writer = std.io.bufferedWriter(std.io.getStdOut().writer());
        defer writer.flush() catch unreachable;
        // FIXME: use writeAll?
        try writer.writer().writeAll(wat);
    }
}
