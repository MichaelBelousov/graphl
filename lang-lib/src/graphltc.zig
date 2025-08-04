const std = @import("std");
const FileBuffer = @import("./FileBuffer.zig");
const compiler = @import("./compiler-wasm.zig");
const Env = @import("./nodes/builtin.zig").Env;
const helpers = @import("./nodes/builtin.zig");
const SexpParser = @import("./sexp_parser.zig").Parser;

pub fn main() !void {
    var exit_code: anyerror!void = {};

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

    // FIXME: temp
    const user_funcs_list = [_]compiler.UserFunc{
        .{
            .id = 1,
            .node = .{
                .name = "Sphere",
                .inputs = try alloc.dupe(helpers.Pin, &.{
                    .{ .name = "", .kind = .{ .primitive = .exec } },
                    .{ .name = "center", .kind = .{ .primitive = .{ .value = helpers.nonprimitive_types.vec3 } } },
                    .{ .name = "radius", .kind = .{ .primitive = .{ .value = helpers.primitive_types.f64_ } } },
                    .{ .name = "color", .kind = .{ .primitive = .{ .value = helpers.primitive_types.string } } },
                }),
                .outputs = try alloc.dupe(helpers.Pin, &.{
                    .{ .name = "", .kind = .{ .primitive = .exec } },
                }),
            },
        },
        .{
            .id = 2,
            .node = .{
                .name = "Box",
                .inputs = try alloc.dupe(helpers.Pin, &.{
                    .{ .name = "", .kind = .{ .primitive = .exec } },
                    .{ .name = "position", .kind = .{ .primitive = .{ .value = helpers.nonprimitive_types.vec3 } } },
                    .{ .name = "dimensions", .kind = .{ .primitive = .{ .value = helpers.nonprimitive_types.vec3 } } },
                    .{ .name = "color", .kind = .{ .primitive = .{ .value = helpers.primitive_types.string } } },
                }),
                .outputs = try alloc.dupe(helpers.Pin, &.{
                    .{ .name = "", .kind = .{ .primitive = .exec } },
                }),
            },
        },
        .{
            .id = 3,
            .node = .{
                // FIXME: replace with just using the vec3 node which should exist...
                .name = "Point",
                .inputs = try alloc.dupe(helpers.Pin, &.{
                    .{ .name = "x", .kind = .{ .primitive = .{ .value = helpers.primitive_types.f64_ } } },
                    .{ .name = "y", .kind = .{ .primitive = .{ .value = helpers.primitive_types.f64_ } } },
                    .{ .name = "z", .kind = .{ .primitive = .{ .value = helpers.primitive_types.f64_ } } },
                }),
                .outputs = try alloc.dupe(helpers.Pin, &.{
                    .{ .name = "", .kind = .{ .primitive = .{ .value = helpers.nonprimitive_types.vec3 } } },
                }),
            },
        },
        // add useless nodes to trigger hashmap expansions
        .{
            .id = 4,
            .node = .{
                // FIXME: replace with just using the vec3 node which should exist...
                .name = "Useless1",
                .inputs = try alloc.dupe(helpers.Pin, &.{ .{ .name = "", .kind = .{ .primitive = .exec } } }),
                .outputs = try alloc.dupe(helpers.Pin, &.{ .{ .name = "", .kind = .{ .primitive = .exec } } }),
            },
        },
        .{
            .id = 5,
            .node = .{
                // FIXME: replace with just using the vec3 node which should exist...
                .name = "Useless2",
                .inputs = try alloc.dupe(helpers.Pin, &.{ .{ .name = "", .kind = .{ .primitive = .exec } } }),
                .outputs = try alloc.dupe(helpers.Pin, &.{ .{ .name = "", .kind = .{ .primitive = .exec } } }),
            },
        },
        .{
            .id = 6,
            .node = .{
                // FIXME: replace with just using the vec3 node which should exist...
                .name = "Useless3",
                .inputs = try alloc.dupe(helpers.Pin, &.{ .{ .name = "", .kind = .{ .primitive = .exec } } }),
                .outputs = try alloc.dupe(helpers.Pin, &.{ .{ .name = "", .kind = .{ .primitive = .exec } } }),
            },
        },
        .{
            .id = 7,
            .node = .{
                // FIXME: replace with just using the vec3 node which should exist...
                .name = "Useless4",
                .inputs = try alloc.dupe(helpers.Pin, &.{ .{ .name = "", .kind = .{ .primitive = .exec } } }),
                .outputs = try alloc.dupe(helpers.Pin, &.{ .{ .name = "", .kind = .{ .primitive = .exec } } }),
            },
        },
    };

    for (&user_funcs_list) |user_func| {
        const node = try alloc.create(std.SinglyLinkedList(compiler.UserFunc).Node);
        node.* = std.SinglyLinkedList(compiler.UserFunc).Node{
            .data = user_func,
        };
        user_funcs.prepend(node);
    }

    var user_func_id: usize = user_funcs_list.len;

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

            const func_name = try alloc.dupeZ(u8, arg_val[0..lpar]);
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
        var parsed = SexpParser.parse(alloc, fb.buffer, &parse_diag) catch |parse_err| {
            std.debug.print("Parse error {} in '{s}':\n{}\n", .{ parse_err, arg, parse_diag });
            exit_code = parse_err;
            continue;
        };

        defer parsed.deinit();

        var compile_diag = compiler.Diagnostic.init();
        const wat = compiler.compile(alloc, &parsed.module, &user_funcs, &compile_diag) catch |compile_err| {
            // FIXME: somehow the pointer in diag (part of &parsed) is invalid when we reach here
            std.debug.print("Compile error {} in '{s}':\n{}\n", .{ compile_err, arg, compile_diag });
            exit_code = compile_err;
            continue;
        };
        defer alloc.free(wat);

        // TODO: invoke wat2wasm
        var writer = std.io.bufferedWriter(std.io.getStdOut().writer());
        defer writer.flush() catch unreachable;
        // FIXME: use writeAll?
        try writer.writer().writeAll(wat);
    }

    return exit_code;
}
