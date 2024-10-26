const std = @import("std");
const Sexp = @import("./sexp.zig").Sexp;
const Env = @import("./nodes//builtin.zig").Env;
const TypeInfo = @import("./nodes//builtin.zig").TypeInfo;
const Type = @import("./nodes//builtin.zig").Type;
const syms = @import("./sexp.zig").syms;
const builtin = @import("./nodes/builtin.zig");
const binaryen = @import("binaryen");

const Context = struct {
    byn_types: std.AutoHashMap(Type, binaryen.Type),

    pub fn init(a: std.mem.Allocator, env: Env) !@This() {
        var result = @This(){
            .byn_types = std.AutoHashMap(Type, binaryen.Type).init(a),
        };

        try result.byn_types.ensureUnusedCapacity(env.types.size);

        result.byn_types.putAssumeCapacity(builtin.primitive_types.i32_, binaryen.Type.int32());
        result.byn_types.putAssumeCapacity(builtin.primitive_types.i64_, binaryen.Type.int64());
        result.byn_types.putAssumeCapacity(builtin.primitive_types.void, binaryen.Type.none());
        result.byn_types.putAssumeCapacity(builtin.primitive_types.f32_, binaryen.Type.float32());
        result.byn_types.putAssumeCapacity(builtin.primitive_types.f64_, binaryen.Type.float64());

        // var env_types_iter = env.types.keyIterator();
        // while (env_types_iter.next()) |env_type| {
        //     result.byn_types.putAssumeCapacity(env_type.*, );
        // }

        return result;
    }

    pub fn deinit(self: *@This()) void {
        self.byn_types.deinit();
    }
};

// initialized by compilation
var shared_context: Context = undefined;

pub fn deinit() void {
    shared_context.deinit();
}

pub const Diagnostic = struct {
    err: Error = .None,

    module: *const Sexp = undefined,

    const Error = union(enum(u16)) {
        None = 0,
        BadTopLevelForm: *const Sexp = 1,
    };

    const Code = error{
        badTopLevelForm,
    };

    pub fn init() @This() {
        return @This(){};
    }
};

const Compilation = struct {
    env: Env,
    // TODO: have a first pass just figure out types?
    /// a list of forms that are incompletely compiled
    deferred: struct {
        /// function with parameter names that need the function's type
        func_decls: std.StringHashMapUnmanaged([]const []const u8) = .{},
        /// typeof's of functions that need function param names
        func_types: std.StringHashMapUnmanaged(TypeInfo) = .{},
    } = .{},
    wasm_module: *binaryen.Module,
    is_wasm_module_moved: bool = false,
    arena: std.heap.ArenaAllocator,
    diag: *Diagnostic,

    pub fn init(alloc: std.mem.Allocator, in_diag: *Diagnostic) !@This() {
        var result = @This(){
            .env = undefined,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .diag = in_diag,
            .wasm_module = binaryen.Module.init(),
        };
        result.env = try Env.initDefault(result.arena.allocator());

        // TODO: use std.once on init?
        shared_context = try Context.init(alloc, result.env);

        return result;
    }

    pub fn deinit(self: *@This()) void {
        const alloc = self.arena.allocator();

        {
            // NOTE: this is a no-op because of the arena
            self.deferred.func_decls.deinit(alloc);
            self.deferred.func_types.deinit(alloc);
            // FIXME: any remaining func_types/func_decls values must be freed!
            self.env.deinit(alloc);
        }

        self.arena.deinit();
        if (!self.is_wasm_module_moved)
            self.wasm_module.deinit();
    }

    fn compileFunc(self: *@This(), sexp: *const Sexp) !bool {
        const alloc = self.arena.allocator();

        if (sexp.value != .list) return false;
        if (sexp.value.list.items.len == 0) return false;
        if (sexp.value.list.items[0].value != .symbol) return error.NonSymbolHead;

        // FIXME: parser should be aware of the define form!
        //if (sexp.value.list.items[0].value.symbol.ptr != syms.define.value.symbol.ptr) return false;
        if (!std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.define.value.symbol)) return false;

        if (sexp.value.list.items[1].value != .list) return false;
        if (sexp.value.list.items[1].value.list.items.len < 1) return error.FuncBindingsListEmpty;
        for (sexp.value.list.items[1].value.list.items) |*def_item| {
            if (def_item.value != .symbol) return error.FuncParamBindingNotSymbol;
        }

        const func_name = sexp.value.list.items[1].value.list.items[0].value.symbol;
        //const params = sexp.value.list.items[1].value.list.items[1..];
        const func_name_mangled = func_name;
        _ = func_name_mangled;

        const func_bindings = sexp.value.list.items[1].value.list.items[1..];

        const func_param_names = try alloc.alloc([]const u8, func_bindings.len);
        for (func_bindings, func_param_names) |func_binding, *param_name| {
            param_name.* = func_binding.value.symbol;
        }

        if (self.deferred.func_types.get(func_name)) |func_type_desc| {
            try self.finishCompileTypedFunc(func_param_names, func_type_desc);
        } else {
            try self.deferred.func_decls.put(alloc, func_name, func_param_names);
        }

        // TODO: search for types first
        // const type_info = self.typeof_map.getPtr(func_name) orelse error.NoSuchType;
        // if (type_info != .@"fn") {
        //     // TODO: fill diagnostic here
        //     return error.FuncBadType;
        // }

        // try writer.print(
        //     \\(type $type_{0s} (func (param i32 i32) (result i32)))
        //     \\(func ${0s} (export "{0s}")
        // , .{func_name_mangled});
        // for (params, type_info.@"fn".params, 0..) |p, ptype, i| {
        //     try writer.print("(param ${s}{} {s}) ", .{ p.value.symbol, i, ptype.name });
        // }
        // TODO: get locals count
        // const locals = [_][]const u8{};
        // for (locals) |l| {
        //     try writer.print("()", .{l});
        // }
        // const result_type = "i32"; // FIXME
        // try writer.print("(result ${s})", .{result_type});

        return true;
    }

    fn compileVar(self: *@This(), sexp: *const Sexp) !bool {
        _ = self;

        if (sexp.value != .list) return false;
        if (sexp.value.list.items.len == 0) return false;
        if (sexp.value.list.items[0].value != .symbol) return error.NonSymbolHead;

        // FIXME: parser should be aware of the define form!
        //if (sexp.value.list.items[0].value.symbol.ptr != syms.define.value.symbol.ptr) return false;
        if (!std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.define.value.symbol)) return false;

        if (sexp.value.list.items[1].value != .symbol) return error.NonSymbolBinding;

        const var_name = sexp.value.list.items[1].value.symbol;
        //const params = sexp.value.list.items[1].value.list.items[1..];
        const var_name_mangled = var_name;
        _ = var_name_mangled;

        //binaryen.Expression;

        return true;
    }

    fn compileTypeOf(self: *@This(), sexp: *const Sexp) !bool {
        if (sexp.value != .list) return error.TypeDeclNotList;
        if (sexp.value.list.items.len == 0) return error.TypeDeclListEmpty;
        if (sexp.value.list.items[0].value != .symbol) return error.NonSymbolHead;
        // FIXME: parser should be aware of the define form!
        //std.debug.assert(sexp.value.list.items[0].value.symbol.ptr == syms.typeof.value.symbol.ptr);
        if (!std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.typeof.value.symbol)) return error.NotATypeDecl;

        return try self.compileTypeOfFunc(sexp) or try self.compileTypeOfVar(sexp);
    }

    /// e.g. (typeof (f i32) i32)
    fn compileTypeOfFunc(self: *@This(), sexp: *const Sexp) !bool {
        const alloc = self.arena.allocator();

        std.debug.assert(sexp.value == .list);
        std.debug.assert(sexp.value.list.items[0].value == .symbol);
        // FIXME: parser should be aware of the define form!
        //std.debug.assert(sexp.value.list.items[0].value.symbol.ptr == syms.typeof.value.symbol.ptr);
        std.debug.assert(std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.typeof.value.symbol));

        if (sexp.value.list.items[1].value != .list) return false;
        if (sexp.value.list.items[1].value.list.items.len == 0) return error.FuncTypeDeclListEmpty;
        for (sexp.value.list.items[1].value.list.items) |*def_item| {
            // FIXME: function types names must be simple symbols (for now)
            if (def_item.value != .symbol) return error.FuncBindingsListEmpty;
        }

        const func_name = sexp.value.list.items[1].value.list.items[0].value.symbol;
        const param_type_exprs = sexp.value.list.items[1].value.list.items[1..];

        // FIXME: types must be symbols (for now)
        if (sexp.value.list.items[2].value != .symbol) return error.FuncTypeDeclResultNotASymbol;

        const result_type_name = sexp.value.list.items[2].value.symbol;

        const param_types = try alloc.alloc(Type, param_type_exprs.len);
        for (param_type_exprs, param_types) |type_expr, *type_| {
            const param_type = type_expr.value.symbol;
            type_.* = self.env.types.getPtr(param_type) orelse return error.UnknownType;
        }

        const return_type = self.env.types.getPtr(result_type_name) orelse return error.UnknownType;

        const func_type_desc = TypeInfo{
            .name = func_name,
            .func_type = .{
                // FIXME: use types to prevent this invalid object!
                // param_names will be filled when the function is not deferred
                .param_types = param_types,
                .return_type = return_type,
            },
        };

        if (self.deferred.func_decls.getPtr(func_name)) |func_decl| {
            try self.finishCompileTypedFunc(func_decl.*, func_type_desc);
        } else {
            try self.deferred.func_types.put(alloc, func_name, func_type_desc);
        }

        return true;
    }

    fn finishCompileTypedFunc(
        self: *@This(),
        func_decl_param_names: []const []const u8,
        incomplete_func_type_desc: TypeInfo,
    ) !void {
        const alloc = self.arena.allocator();

        const complete_func_type_desc = TypeInfo{
            .name = incomplete_func_type_desc.name,
            .func_type = .{
                .param_names = func_decl_param_names,
                .param_types = incomplete_func_type_desc.func_type.?.param_types,
                .return_type = incomplete_func_type_desc.func_type.?.return_type,
            },
        };

        const func_type = try self.env.addType(alloc, complete_func_type_desc);

        _ = func_type;

        const byn_param_types = try alloc.alloc(binaryen.Type, complete_func_type_desc.func_type.?.param_types.len);
        // FIXME
        for (byn_param_types) |*param| param.* = binaryen.Type.int32();
        const byn_param_type = binaryen.Type.create(byn_param_types);

        const byn_result_type = binaryen.Type.int32();

        const byn_locals_types = try alloc.alloc(binaryen.Type, complete_func_type_desc.func_type.?.param_types.len);
        for (byn_locals_types) |*local| local.* = binaryen.Type.int32();

        const x = binaryen.Expression.localGet(self.wasm_module, 0, binaryen.Type.int32());
        const y = binaryen.Expression.localGet(self.wasm_module, 1, binaryen.Type.int32());
        const body = binaryen.Expression.binaryOp(self.wasm_module, binaryen.Expression.Op.addInt32(), x, y);

        // FIXME: leak
        const namez = try alloc.dupeZ(u8, complete_func_type_desc.name);
        _ = self.wasm_module.addFunction(namez, byn_param_type, byn_result_type, byn_locals_types, body);
    }

    fn compileTypeOfVar(self: *@This(), sexp: *const Sexp) !bool {
        _ = self;
        std.debug.assert(sexp.value == .list);
        std.debug.assert(sexp.value.list.items[0].value == .symbol);
        // FIXME: parser should be aware of the define form!
        //std.debug.assert(sexp.value.list.items[0].value.symbol.ptr == syms.typeof.value.symbol.ptr);
        std.debug.assert(std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.typeof.value.symbol));

        if (sexp.value.list.items[1].value != .symbol) return false;
        // shit, I need to evaluate macros in the compiler, don't I
        if (sexp.value.list.items[2].value != .symbol) return error.VarTypeNotSymbol;

        const var_name = sexp.value.list.items[1].value.symbol;
        _ = var_name;
        const type_name = sexp.value.list.items[2].value.symbol;
        _ = type_name;

        return true;
    }

    pub fn compileModule(self: *@This(), sexp: *const Sexp) !*binaryen.Module {
        std.debug.assert(sexp.value == .module);

        for (sexp.value.module.items) |decl| {
            switch (decl.value) {
                .list => {
                    const did_compile = (try self.compileFunc(&decl) or
                        try self.compileVar(&decl) or
                        try self.compileTypeOf(&decl));
                    if (!did_compile) {
                        self.diag.err = Diagnostic.Error{ .BadTopLevelForm = &decl };
                        return error.badTopLevelForm;
                    }
                },
                else => {
                    self.diag.err = Diagnostic.Error{ .BadTopLevelForm = &decl };
                    return error.badTopLevelForm;
                },
            }
        }

        // FIXME: need to free this!
        const wasm_module = self.wasm_module;
        self.wasm_module = undefined;
        self.is_wasm_module_moved = true;
        return wasm_module;
    }
};

pub fn compile(a: std.mem.Allocator, sexp: *const Sexp, _in_diagnostic: ?*Diagnostic) !*binaryen.Module {
    var ignored_diagnostic: Diagnostic = undefined; // FIXME: why don't we init?
    const diag = if (_in_diagnostic) |d| d else &ignored_diagnostic;
    diag.module = sexp;

    var unit = try Compilation.init(a, diag);
    defer unit.deinit();

    return unit.compileModule(sexp);
}

const t = std.testing;
const SexpParser = @import("./sexp_parser.zig").Parser;

test "parse" {
    defer deinit();

    var parsed = try SexpParser.parse(t.allocator,
        \\;;; comment
        \\(typeof x i32)
        \\(define x 10)
        \\;;; comment
        \\(typeof (++ i32) i32)
        \\(define (++ x) (+ x 1))
    , null);
    std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit(t.allocator);

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &diagnostic)) |result| {
        const wat = result.emitText();
        try t.expectEqualStrings(
            \\(module
            \\ (type $i32_=>_i32 (func (param i32) (result i32)))
            \\ (func $++ (param $0 i32) (result i32)
            \\  (local $1 i32)
            \\  (i32.add
            \\   (local.get $0)
            \\   (local.get $1)
            \\  )
            \\ )
            \\)
            \\
        , wat);
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
    }
}
