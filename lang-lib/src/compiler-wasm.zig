//! WebAssembly binary compiler backend using Binaryen
//! This provides similar functionality to compiler-wat.zig but outputs binary WASM

const std = @import("std");
const binaryen = @import("binaryen");
const builtin = @import("./nodes/builtin.zig");
const primitive_types = builtin.primitive_types;
const Env = builtin.Env;
const Type = builtin.Type;
const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;
const intrinsics = @import("./intrinsics.zig");

pub const Diagnostic = struct {
    err: Error = .None,
    module: *const Sexp = undefined,

    const Error = union(enum(u16)) {
        None = 0,
        BadTopLevelForm: *const Sexp = 1,
    };

    pub fn init() @This() {
        return .{};
    }

    pub fn format(
        self: @This(),
        comptime fmt_str: []const u8,
        fmt_opts: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt_str;
        _ = fmt_opts;
        switch (self.err) {
            .None => try writer.print("Not an error", .{}),
            .BadTopLevelForm => |decl| {
                try writer.print("Bad Top Level Form:\n{}\n", .{decl});
                try writer.print("in:\n{}\n", .{self.module});
            },
        }
    }
};

pub const UserFunc = struct {
    id: usize,
    node: builtin.BasicMutNodeDesc,
};

const DeferredFuncDeclInfo = struct {
    param_names: []const []const u8,
    local_names: []const []const u8,
    local_types: []const Type,
    local_defaults: []const Sexp,
    result_names: []const []const u8,
    body_exprs: []const Sexp,
};

const DeferredFuncTypeInfo = struct {
    param_types: []const Type,
    result_types: []const Type,
};

const Compilation = struct {
    module: *binaryen.Module,
    env: *Env,
    arena: std.heap.ArenaAllocator,
    deferred: struct {
        func_decls: std.StringHashMapUnmanaged(DeferredFuncDeclInfo) = .{},
        func_types: std.StringHashMapUnmanaged(DeferredFuncTypeInfo) = .{},
    } = .{},
    user_context: struct {
        funcs: *const std.SinglyLinkedList(UserFunc),
    },
    diag: *Diagnostic,
    next_global_data_ptr: usize = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        env: *Env,
        user_funcs: ?*const std.SinglyLinkedList(UserFunc),
        in_diag: *Diagnostic,
    ) !@This() {
        var empty_user_funcs = std.SinglyLinkedList(UserFunc){};

        const module = binaryen.Module.init();
        errdefer module.deinit();

        // Set up memory
        module.setMemory(1, 256, "memory", &.{}, &.{}, null);
        module.setFeatures(binaryen.Features.all());

        return .{
            .module = module,
            .env = env,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .diag = in_diag,
            .user_context = .{
                .funcs = user_funcs orelse &empty_user_funcs,
            },
        };
    }

    pub fn deinit(self: *@This()) void {
        self.module.deinit();
        self.arena.deinit();
    }

    fn addReadonlyData(self: *@This(), data: []const u8) !usize {
        const offset = self.next_global_data_ptr;
        const segment = binaryen.Segment{
            .offset = offset,
            .data = data,
            .passive = false,
        };
        try self.module.addDataSegment("data", segment);
        self.next_global_data_ptr += data.len;
        return offset;
    }

    fn compileExpr(
        self: *@This(),
        code_sexp: *const Sexp,
        context: *ExprContext,
    ) !*binaryen.Expression {
        const alloc = self.arena.allocator();

        switch (code_sexp.value) {
            .list => |list| {
                if (list.items.len == 0) return error.EmptyList;
                
                const head = list.items[0];
                if (head.value != .symbol) return error.NonSymbolHead;

                // Handle special forms
                if (std.mem.eql(u8, head.value.symbol, "if")) {
                    if (list.items.len != 4) return error.InvalidIfForm;
                    
                    const condition = try self.compileExpr(&list.items[1], context);
                    const then_expr = try self.compileExpr(&list.items[2], context);
                    const else_expr = try self.compileExpr(&list.items[3], context);

                    return self.module.makeIf(condition, then_expr, else_expr);
                }

                // Handle function calls
                if (self.env.getNode(head.value.symbol)) |func_node| {
                    var args = try std.ArrayList(*binaryen.Expression).initCapacity(
                        alloc,
                        list.items.len - 1
                    );
                    defer args.deinit();

                    for (list.items[1..]) |arg| {
                        const compiled_arg = try self.compileExpr(&arg, context);
                        try args.append(compiled_arg);
                    }

                    return self.module.makeCall(
                        head.value.symbol,
                        args.items,
                        self.getBinaryenType(func_node.getOutputs()[0].kind.primitive.value)
                    );
                }

                return error.UnknownFunction;
            },

            .int => |v| {
                return self.module.makeConst(.{ .type = .i32, .value = v });
            },

            .float => |v| {
                return self.module.makeConst(.{ .type = .f64, .value = v });
            },

            .symbol => |sym| {
                // Handle local variable references
                for (context.local_names, 0..) |name, i| {
                    if (std.mem.eql(u8, name, sym)) {
                        return self.module.makeLocalGet(
                            @intCast(i),
                            self.getBinaryenType(context.local_types[i])
                        );
                    }
                }

                // Handle parameter references
                for (context.param_names, 0..) |name, i| {
                    if (std.mem.eql(u8, name, sym)) {
                        return self.module.makeLocalGet(
                            @intCast(i),
                            self.getBinaryenType(context.param_types[i])
                        );
                    }
                }

                return error.UnknownSymbol;
            },

            else => return error.UnsupportedExpressionType,
        }
    }

    fn getBinaryenType(self: *@This(), type_: Type) binaryen.Type {
        _ = self;
        return switch (type_) {
            primitive_types.i32_ => .i32,
            primitive_types.i64_ => .i64,
            primitive_types.f32_ => .f32,
            primitive_types.f64_ => .f64,
            else => .auto, // Default fallback
        };
    }

    pub fn compileModule(self: *@This(), sexp: *const Sexp) ![]const u8 {
        std.debug.assert(sexp.value == .module);

        // Add imports
        try self.addImports();

        // Add intrinsics
        try self.addIntrinsics();

        // Compile declarations
        for (sexp.value.module.items) |decl| {
            switch (decl.value) {
                .list => {
                    const did_compile = (try self.compileFunc(&decl) or
                        try self.compileVar(&decl) or
                        try self.compileTypeOf(&decl));
                    if (!did_compile) {
                        self.diag.err = .{ .BadTopLevelForm = &decl };
                        return error.BadTopLevelForm;
                    }
                },
                else => {
                    self.diag.err = .{ .BadTopLevelForm = &decl };
                    return error.BadTopLevelForm;
                },
            }
        }

        // Validate and optimize
        if (!self.module.validate()) {
            return error.InvalidModule;
        }

        // Optimize
        self.module.optimize();

        // Generate binary
        return self.module.emitBinary();
    }

    fn addImports(self: *@This()) !void {
        // Add standard environment imports
        const imports = [_]struct {
            name: []const u8,
            params: []const binaryen.Type,
            results: []const binaryen.Type,
        }{
            .{
                .name = "callUserFunc_code_R",
                .params = &.{ .i32, .i32, .i32 },
                .results = &.{},
            },
            .{
                .name = "callUserFunc_code_R_string",
                .params = &.{ .i32, .i32, .i32 },
                .results = &.{.i32},
            },
            // Add other imports...
        };

        for (imports) |import| {
            _ = try self.module.addFunctionImport(
                import.name,
                "env",
                import.name,
                import.params,
                import.results
            );
        }
    }

    fn addIntrinsics(self: *@This()) !void {
        // Add intrinsic functions from the intrinsics module
        // This would involve converting the WAT intrinsics to Binaryen expressions
        _ = self;
        // TODO: Implement intrinsics
    }

    fn compileFunc(self: *@This(), sexp: *const Sexp) !bool {
        const alloc = self.arena.allocator();

        if (sexp.value != .list) return false;
        if (sexp.value.list.items.len == 0) return false;
        if (sexp.value.list.items[0].value != .symbol) return error.NonSymbolHead;

        // Check if this is a function definition
        if (!std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.define.value.symbol)) return false;

        if (sexp.value.list.items.len <= 2) return false;
        if (sexp.value.list.items[1].value != .list) return false;
        if (sexp.value.list.items[1].value.list.items.len < 1) return error.FuncBindingsListEmpty;
        
        // Validate parameter bindings are symbols
        for (sexp.value.list.items[1].value.list.items) |*def_item| {
            if (def_item.value != .symbol) return error.FuncParamBindingNotSymbol;
        }

        // Check function body
        if (sexp.value.list.items.len < 3) return error.FuncWithoutBody;
        const body = sexp.value.list.items[2];
        if (body.value != .list) return error.FuncBodyNotList;
        if (body.value.list.items.len < 1) return error.FuncBodyWithoutBegin;
        if (body.value.list.items[0].value != .symbol) return error.FuncBodyWithoutBegin;
        if (!std.mem.eql(u8, body.value.list.items[0].value.symbol, syms.begin.value.symbol)) return error.FuncBodyWithoutBegin;

        // Process local variables
        var local_names = std.ArrayList([]const u8).init(alloc);
        defer local_names.deinit();

        var local_types = std.ArrayList(Type).init(alloc);
        defer local_types.deinit();

        var local_defaults = std.ArrayList(Sexp).init(alloc);
        defer local_defaults.deinit();

        var first_non_def: usize = 0;
        for (body.value.list.items[1..], 1..) |maybe_local_def, i| {
            first_non_def = i;
            // Check if this is a local definition
            if (maybe_local_def.value != .list) break;
            if (maybe_local_def.value.list.items.len < 3) break;
            if (!std.mem.eql(u8, maybe_local_def.value.list.items[0].value.symbol, syms.define.value.symbol) and
                !std.mem.eql(u8, maybe_local_def.value.list.items[0].value.symbol, syms.typeof.value.symbol)) break;
            if (maybe_local_def.value.list.items[1].value != .symbol) return error.LocalBindingNotSymbol;

            const is_typeof = std.mem.eql(u8, maybe_local_def.value.list.items[0].value.symbol, syms.typeof.value.symbol);
            const local_name = maybe_local_def.value.list.items[1].value.symbol;

            if (is_typeof) {
                const local_type = maybe_local_def.value.list.items[2];
                if (local_type.value != .symbol) return error.LocalBindingTypeNotSymbol;
                (try local_types.addOne()).* = self.env.getType(local_type.value.symbol) orelse return error.TypeNotFound;
            } else {
                const local_default = maybe_local_def.value.list.items[2];
                (try local_defaults.addOne()).* = local_default;
                (try local_names.addOne()).* = local_name;
            }
        }

        const return_exprs = body.value.list.items[first_non_def..];
        const func_name = sexp.value.list.items[1].value.list.items[0].value.symbol;
        const func_bindings = sexp.value.list.items[1].value.list.items[1..];

        const param_names = try alloc.alloc([]const u8, func_bindings.len);
        errdefer alloc.free(param_names);

        for (func_bindings, param_names) |func_binding, *param_name| {
            param_name.* = func_binding.value.symbol;
        }

        const func_desc = DeferredFuncDeclInfo{
            .param_names = param_names,
            .local_names = try local_names.toOwnedSlice(),
            .local_types = try local_types.toOwnedSlice(),
            .local_defaults = try local_defaults.toOwnedSlice(),
            .result_names = &.{},
            .body_exprs = return_exprs,
        };

        if (self.deferred.func_types.get(func_name)) |func_type| {
            try self.finishCompileTypedFunc(func_name, func_desc, func_type);
        } else {
            try self.deferred.func_decls.put(alloc, func_name, func_desc);
        }

        return true;
    }

    fn finishCompileTypedFunc(
        self: *@This(),
        name: []const u8,
        func_decl: DeferredFuncDeclInfo,
        func_type: DeferredFuncTypeInfo,
    ) !void {
        const alloc = self.arena.allocator();

        // Convert parameter types to Binaryen types
        var param_types = try std.ArrayList(binaryen.Type).initCapacity(alloc, func_type.param_types.len);
        defer param_types.deinit();

        for (func_type.param_types) |param_type| {
            try param_types.append(self.getBinaryenType(param_type));
        }

        // Convert result types to Binaryen types
        var result_types = try std.ArrayList(binaryen.Type).initCapacity(alloc, func_type.result_types.len);
        defer result_types.deinit();

        for (func_type.result_types) |result_type| {
            try result_types.append(self.getBinaryenType(result_type));
        }

        // Create function type
        const func_type_name = try std.fmt.allocPrint(alloc, "$typeof_{s}", .{name});
        defer alloc.free(func_type_name);

        // Create function
        var locals = std.ArrayList(binaryen.Type).init(alloc);
        defer locals.deinit();

        // Add local variable types
        for (func_decl.local_types) |local_type| {
            try locals.append(self.getBinaryenType(local_type));
        }

        // Compile function body
        var next_local: usize = 0;
        var context = ExprContext{
            .local_names = func_decl.local_names,
            .local_types = func_decl.local_types,
            .param_names = func_decl.param_names,
            .param_types = func_type.param_types,
            .next_local = &next_local,
        };

        var body_exprs = std.ArrayList(*binaryen.Expression).init(alloc);
        defer body_exprs.deinit();

        // Compile local variable initializations
        for (func_decl.local_defaults, 0..) |default_expr, i| {
            const init_expr = try self.compileExpr(&default_expr, &context);
            const set_local = self.module.makeLocalSet(@intCast(i), init_expr);
            try body_exprs.append(set_local);
        }

        // Compile function body expressions
        for (func_decl.body_exprs) |body_expr| {
            const compiled_expr = try self.compileExpr(body_expr, &context);
            try body_exprs.append(compiled_expr);
        }

        // Create block containing all expressions
        const body_block = self.module.makeBlock(
            "body",
            body_exprs.items,
            if (func_type.result_types.len > 0)
                self.getBinaryenType(func_type.result_types[0])
            else
                .none
        );

        // Add function to module
        _ = try self.module.addFunction(
            name,
            param_types.items,
            result_types.items,
            locals.items,
            body_block
        );

        // Export the function
        try self.module.addFunctionExport(name, name);
    }

    // ... implement remaining compiler functionality
};

const ExprContext = struct {
    type: ?Type = null,
    local_names: []const []const u8,
    local_types: []const Type,
    param_names: []const []const u8,
    param_types: []const Type,
    frame: struct {
        byte_size: usize = 0,
    } = .{},
    next_local: *usize,
};

pub fn compile(
    alloc: std.mem.Allocator,
    sexp: *const Sexp,
    env: *const Env,
    user_funcs: ?*const std.SinglyLinkedList(UserFunc),
    in_diagnostic: ?*Diagnostic,
) ![]const u8 {
    var ignored_diagnostic: Diagnostic = undefined;
    const diag = if (in_diagnostic) |d| d else &ignored_diagnostic;
    diag.module = sexp;

    var mut_env = env.spawn();

    var unit = try Compilation.init(alloc, &mut_env, user_funcs, diag);
    defer unit.deinit();

    return unit.compileModule(sexp);
}

test "basic compilation" {
    var env = try Env.initDefault(t.allocator);
    defer env.deinit(t.allocator);

    // Add factorial function to environment
    _ = try env.addNode(t.allocator, builtin.basicNode(&.{
        .name = "factorial",
        .inputs = &.{
            builtin.Pin{ .name = "in", .kind = .{ .primitive = .exec } },
            builtin.Pin{ .name = "n", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            builtin.Pin{ .name = "out", .kind = .{ .primitive = .exec } },
            builtin.Pin{ .name = "n", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
    }));

    var parsed = try SexpParser.parse(t.allocator,
        \\(typeof (factorial i32) i32)
        \\(define (factorial n)
        \\  (begin
        \\    (if (<= n 1)
        \\        (begin (return 1))
        \\        (begin (return (* n (factorial (- n 1))))))))
        \\
    , null);
    defer parsed.deinit(t.allocator);

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &env, null, &diagnostic)) |wasm_binary| {
        defer t.allocator.free(wasm_binary);

        // Write binary to temp file for inspection if needed
        {
            var tmp_dir = try std.fs.openDirAbsolute("/tmp", .{});
            defer tmp_dir.close();

            var dbg_file = try tmp_dir.createFile("compiler-test.wasm", .{});
            defer dbg_file.close();
            try dbg_file.writeAll(wasm_binary);
        }

        // Load and validate the WASM module
        const module_def = try bytebox.createModuleDefinition(t.allocator, .{});
        defer module_def.destroy();

        try module_def.decode(wasm_binary);

        const module_instance = try bytebox.createModuleInstance(.Stack, module_def, t.allocator);
        defer module_instance.destroy();

        // Add required imports
        var imports = try bytebox.ModuleImportPackage.init("env", null, null, t.allocator);
        defer imports.deinit();

        // Add host function stubs
        const Local = struct {
            fn nullHostFunc(user_data: ?*anyopaque, _module: *bytebox.ModuleInstance, _params: [*]const bytebox.Val, _returns: [*]bytebox.Val) void {
                _ = user_data;
                _ = _module;
                _ = _params;
                _ = _returns;
            }
        };

        // Add required imports
        inline for (&.{
            .{ "callUserFunc_code_R", &.{ .I32, .I32, .I32 }, &.{} },
            .{ "callUserFunc_code_R_string", &.{ .I32, .I32, .I32 }, &.{.I32} },
            .{ "callUserFunc_string_R", &.{ .I32, .I32, .I32 }, &.{} },
            .{ "callUserFunc_R", &.{.I32}, &.{} },
            .{ "callUserFunc_i32_R", &.{ .I32, .I32 }, &.{} },
            .{ "callUserFunc_i32_R_i32", &.{ .I32, .I32 }, &.{.I32} },
            .{ "callUserFunc_i32_i32_R_i32", &.{ .I32, .I32, .I32 }, &.{.I32} },
            .{ "callUserFunc_bool_R", &.{ .I32, .I32 }, &.{} },
        }) |import_desc| {
            const name, const params, const results = import_desc;
            try imports.addHostFunction(name, params, results, Local.nullHostFunc, null);
        }

        try module_instance.instantiate(.{
            .imports = &.{imports},
        });

        // Test factorial(3)
        const handle = try module_instance.getFunctionHandle("factorial");
        var args = [_]bytebox.Val{bytebox.Val{ .I32 = 3 }};
        var results = [_]bytebox.Val{bytebox.Val{ .I32 = 0 }};
        try module_instance.invoke(handle, &args, &results, .{});

        try t.expectEqual(results[0].I32, 6); // factorial(3) should be 6
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
} 