const zig_builtin = @import("builtin");
const std = @import("std");
const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;
const primitive_type_syms = @import("./sexp.zig").primitive_type_syms;
const builtin = @import("./nodes/builtin.zig");
const primitive_types = @import("./nodes/builtin.zig").primitive_types;
const Env = @import("./nodes//builtin.zig").Env;
const TypeInfo = @import("./nodes//builtin.zig").TypeInfo;
const Type = @import("./nodes/builtin.zig").Type;

const intrinsics_raw = @embedFile("grappl_intrinsics");
const intrinsics_code = intrinsics_raw["(module $grappl_intrinsics.wasm\n".len .. intrinsics_raw.len - 2];

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

const DeferredFuncDeclInfo = struct {
    param_names: []const []const u8,
    local_names: []const []const u8,
    local_types: []const Type,
    local_defaults: []const Sexp,
    result_names: []const []const u8,
    return_exprs: []const Sexp,
};

const DeferredFuncTypeInfo = struct {
    param_types: []const Type,
    result_types: []const Type,
};

var empty_user_funcs = std.SinglyLinkedList(builtin.BasicMutNodeDesc){};

fn writeWasmMemoryString(data: []const u8, writer: anytype) !void {
    for (data) |char| {
        switch (char) {
            '\\' => {
                try writer.writeAll("\\\\");
            },
            // printable ascii not including backslash
            ' '...'[', ']'...127 => {
                try writer.writeByte(char);
            },
            // FIXME: use ascii bit magic here, I'm too lazy and time pressed
            else => {
                try writer.writeByte('\\');
                try std.fmt.formatInt(char, 16, .lower, .{ .width = 2, .fill = '0' }, writer);
            },
        }
    }
}

const Compilation = struct {
    env: Env,
    // TODO: have a first pass just figure out types?
    /// a list of forms that are incompletely compiled
    deferred: struct {
        /// function with parameter names that need the function's type
        func_decls: std.StringHashMapUnmanaged(DeferredFuncDeclInfo) = .{},
        /// typeof's of functions that need function param names
        func_types: std.StringHashMapUnmanaged(DeferredFuncTypeInfo) = .{},
    } = .{},
    /// the WAT output
    wat: Sexp,
    /// the body of the (module ) at the top level of the WAT output
    module_body: *std.ArrayList(Sexp),
    arena: std.heap.ArenaAllocator,
    user_context: struct {
        funcs: *std.SinglyLinkedList(builtin.BasicMutNodeDesc),
    },
    diag: *Diagnostic,

    next_global_data_ptr: usize = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        user_funcs: ?*std.SinglyLinkedList(builtin.BasicMutNodeDesc),
        in_diag: *Diagnostic,
    ) !@This() {
        const result = @This(){
            .arena = std.heap.ArenaAllocator.init(alloc),
            .diag = in_diag,
            // FIXME: these are set in the main public entry, once we know
            // the caller has settled on where they are putting this object
            .env = undefined,
            .wat = undefined,
            .module_body = undefined,
            .user_context = .{
                .funcs = user_funcs orelse &empty_user_funcs,
            },
        };

        return result;
    }

    pub fn deinit(self: *@This()) void {
        // NOTE: this is a no-op because of the arena
        // FIXME: any remaining func_types/func_decls values must be freed!
        //self.deferred.func_decls.deinit(alloc);
        //self.deferred.func_types.deinit(alloc);
        //self.env.deinit(alloc);
        //self.wat.deinit(self.arena.deinit());

        self.arena.deinit();
    }

    fn compileFunc(self: *@This(), sexp: *const Sexp) !bool {
        const alloc = self.arena.allocator();

        if (sexp.value != .list) return false;
        if (sexp.value.list.items.len == 0) return false;
        if (sexp.value.list.items[0].value != .symbol) return error.NonSymbolHead;

        // FIXME: parser should be aware of the define form!
        //if (sexp.value.list.items[0].value.symbol.ptr != syms.define.value.symbol.ptr) return false;
        if (!std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.define.value.symbol)) return false;

        if (sexp.value.list.items.len <= 2) return false;
        if (sexp.value.list.items[1].value != .list) return false;
        if (sexp.value.list.items[1].value.list.items.len < 1) return error.FuncBindingsListEmpty;
        for (sexp.value.list.items[1].value.list.items) |*def_item| {
            if (def_item.value != .symbol) return error.FuncParamBindingNotSymbol;
        }

        if (sexp.value.list.items.len < 3) return error.FuncWithoutBody;
        const body = sexp.value.list.items[2];
        // NOTE: if there are no locals this should be ok!
        if (body.value != .list) return error.FuncBodyNotList;
        if (body.value.list.items.len < 1) return error.FuncBodyWithoutBegin;
        if (body.value.list.items[0].value != .symbol) return error.FuncBodyWithoutBegin;
        if (body.value.list.items[0].value.symbol.ptr != syms.begin.value.symbol.ptr) return error.FuncBodyWithoutBegin;

        if (body.value.list.items.len < 2) return error.FuncBodyWithoutImmediateReturn;
        const last_in_begin = &body.value.list.items[body.value.list.items.len - 1];
        if (last_in_begin.value != .list) return error.FuncBodyBeginReturnNotList;
        if (last_in_begin.value.list.items.len < 1) return error.FuncBodyNotEndingInReturn;
        const return_sym = &last_in_begin.value.list.items[0];
        if (return_sym.value.symbol.ptr != syms.@"return".value.symbol.ptr) return error.FuncBodyNotEndingInReturn;

        var local_names = std.ArrayList([]const u8).init(alloc);
        defer local_names.deinit();

        var local_types = std.ArrayList(Type).init(alloc);
        defer local_types.deinit();

        var local_defaults = std.ArrayList(Sexp).init(alloc);
        defer local_defaults.deinit();

        var first_non_def: usize = 0;
        for (body.value.list.items[1..], 1..) |maybe_local_def, i| {
            first_non_def = i;
            // locals are all in one block at the beginning. If it's not a local def, stop looking for more
            if (maybe_local_def.value != .list) break;
            if (maybe_local_def.value.list.items.len < 3) break;
            if (maybe_local_def.value.list.items[0].value.symbol.ptr != syms.define.value.symbol.ptr and maybe_local_def.value.list.items[0].value.symbol.ptr != syms.typeof.value.symbol.ptr)
                break;
            if (maybe_local_def.value.list.items[1].value != .symbol) return error.LocalBindingNotSymbol;

            const is_typeof = maybe_local_def.value.list.items[0].value.symbol.ptr == syms.typeof.value.symbol.ptr;
            const local_name = maybe_local_def.value.list.items[1].value.symbol;

            // FIXME: typeofs must come before or after because the name isn't inserted in order!
            if (is_typeof) {
                const local_type = maybe_local_def.value.list.items[2];
                if (local_type.value != .symbol)
                    return error.LocalBindingTypeNotSymbol;
                // TODO: diagnostic
                (try local_types.addOne()).* = self.env.types.get(local_type.value.symbol) orelse return error.TypeNotFound;
            } else {
                const local_default = maybe_local_def.value.list.items[2];
                (try local_defaults.addOne()).* = local_default;
                (try local_names.addOne()).* = local_name;
            }
        }

        std.debug.assert(first_non_def < body.value.list.items.len);

        const return_exprs = body.value.list.items[first_non_def..];

        const func_name = sexp.value.list.items[1].value.list.items[0].value.symbol;
        //const params = sexp.value.list.items[1].value.list.items[1..];
        const func_name_mangled = func_name;
        _ = func_name_mangled;

        const func_bindings = sexp.value.list.items[1].value.list.items[1..];

        const param_names = try alloc.alloc([]const u8, func_bindings.len);
        errdefer alloc.free(param_names);

        for (func_bindings, param_names) |func_binding, *param_name| {
            param_name.* = func_binding.value.symbol;
        }

        const func_desc = DeferredFuncDeclInfo{
            .param_names = param_names,
            // TODO: read all defines at beginning of sexp or something
            .local_names = try local_names.toOwnedSlice(),
            .local_types = try local_types.toOwnedSlice(),
            .local_defaults = try local_defaults.toOwnedSlice(),
            .result_names = &.{},
            .return_exprs = return_exprs,
        };

        if (self.deferred.func_types.get(func_name)) |func_type| {
            try self.finishCompileTypedFunc(func_name, func_desc, func_type);
        } else {
            try self.deferred.func_decls.put(alloc, func_name, func_desc);
        }

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
        errdefer alloc.free(param_types);
        for (param_type_exprs, param_types) |type_expr, *type_| {
            const param_type = type_expr.value.symbol;
            type_.* = self.env.types.get(param_type) orelse return error.UnknownType;
        }

        const result_types = try alloc.alloc(Type, 1);
        errdefer alloc.free(result_types);
        result_types[0] = self.env.types.get(result_type_name) orelse return error.UnknownType;

        const func_type_desc = DeferredFuncTypeInfo{
            .param_types = param_types,
            .result_types = result_types,
        };

        if (self.deferred.func_decls.getPtr(func_name)) |func_decl| {
            try self.finishCompileTypedFunc(func_name, func_decl.*, func_type_desc);
        } else {
            try self.deferred.func_types.put(alloc, func_name, func_type_desc);
        }

        return true;
    }

    const wat_syms = struct {
        pub const call = Sexp{ .value = .{ .symbol = "call" } };
        pub const module = Sexp{ .value = .{ .symbol = "module" } };
        pub const @"type" = Sexp{ .value = .{ .symbol = "type" } };
        pub const @"export" = Sexp{ .value = .{ .symbol = "export" } };
        pub const func = Sexp{ .value = .{ .symbol = "func" } };
        pub const param = Sexp{ .value = .{ .symbol = "param" } };
        pub const result = Sexp{ .value = .{ .symbol = "result" } };
        pub const local = Sexp{ .value = .{ .symbol = "local" } };
        pub const memory = Sexp{ .value = .{ .symbol = "memory" } };
        pub const @"$0" = Sexp{ .value = .{ .symbol = "$0" } };
        pub const data = Sexp{ .value = .{ .symbol = "data" } };

        pub const ops = struct {
            pub const @"local.get" = Sexp{ .value = .{ .symbol = "local.get" } };
            pub const @"local.set" = Sexp{ .value = .{ .symbol = "local.set" } };

            pub const i32_ = struct {
                pub const add = Sexp{ .value = .{ .symbol = "i32.add" } };
                pub const sub = Sexp{ .value = .{ .symbol = "i32.sub" } };
                pub const mul = Sexp{ .value = .{ .symbol = "i32.mul" } };
                pub const div = Sexp{ .value = .{ .symbol = "i32.div" } };
                pub const rem = Sexp{ .value = .{ .symbol = "i32.rem" } };
                pub const gt = Sexp{ .value = .{ .symbol = "i32.gt_s" } };
                pub const ge = Sexp{ .value = .{ .symbol = "i32.ge_s" } };
                pub const lt = Sexp{ .value = .{ .symbol = "i32.lt_s" } };
                pub const le = Sexp{ .value = .{ .symbol = "i32.le_s" } };
                pub const ne = Sexp{ .value = .{ .symbol = "i32.ne" } };
                pub const eq = Sexp{ .value = .{ .symbol = "i32.eq" } };
                pub const @"const" = Sexp{ .value = .{ .symbol = "i32.const" } };
            };

            pub const u32_ = struct {
                pub const add = Sexp{ .value = .{ .symbol = "i32.add" } };
                pub const sub = Sexp{ .value = .{ .symbol = "i32.sub" } };
                pub const mul = Sexp{ .value = .{ .symbol = "i32.mul" } };
                pub const div = Sexp{ .value = .{ .symbol = "i32.div" } };
                pub const rem = Sexp{ .value = .{ .symbol = "i32.rem" } };
                pub const gt = Sexp{ .value = .{ .symbol = "i32.gt_u" } };
                pub const ge = Sexp{ .value = .{ .symbol = "i32.ge_u" } };
                pub const lt = Sexp{ .value = .{ .symbol = "i32.lt_u" } };
                pub const le = Sexp{ .value = .{ .symbol = "i32.le_u" } };
                pub const ne = Sexp{ .value = .{ .symbol = "i32.ne" } };
                pub const eq = Sexp{ .value = .{ .symbol = "i32.eq" } };
                pub const @"const" = Sexp{ .value = .{ .symbol = "i32.const" } };
            };

            pub const i64_ = struct {
                pub const add = Sexp{ .value = .{ .symbol = "i64.add" } };
                pub const sub = Sexp{ .value = .{ .symbol = "i64.sub" } };
                pub const mul = Sexp{ .value = .{ .symbol = "i64.mul" } };
                pub const div = Sexp{ .value = .{ .symbol = "i64.div" } };
                pub const rem = Sexp{ .value = .{ .symbol = "i64.rem" } };
                pub const gt = Sexp{ .value = .{ .symbol = "i64.gt_s" } };
                pub const ge = Sexp{ .value = .{ .symbol = "i64.ge_s" } };
                pub const lt = Sexp{ .value = .{ .symbol = "i64.lt_s" } };
                pub const le = Sexp{ .value = .{ .symbol = "i64.le_s" } };
                pub const ne = Sexp{ .value = .{ .symbol = "i64.ne" } };
                pub const eq = Sexp{ .value = .{ .symbol = "i64.eq" } };
                pub const @"const" = Sexp{ .value = .{ .symbol = "i64.const" } };

                pub const extend_i32_s = Sexp{ .value = .{ .symbol = "i64.extend_i32_s" } };
                pub const extend_i32_u = Sexp{ .value = .{ .symbol = "i64.extend_i32_u" } };
            };

            pub const u64_ = struct {
                pub const add = Sexp{ .value = .{ .symbol = "i64.add" } };
                pub const sub = Sexp{ .value = .{ .symbol = "i64.sub" } };
                pub const mul = Sexp{ .value = .{ .symbol = "i64.mul" } };
                pub const div = Sexp{ .value = .{ .symbol = "i64.div" } };
                pub const rem = Sexp{ .value = .{ .symbol = "i64.rem" } };
                pub const gt = Sexp{ .value = .{ .symbol = "i64.gt_u" } };
                pub const ge = Sexp{ .value = .{ .symbol = "i64.ge_u" } };
                pub const lt = Sexp{ .value = .{ .symbol = "i64.lt_u" } };
                pub const le = Sexp{ .value = .{ .symbol = "i64.le_u" } };
                pub const ne = Sexp{ .value = .{ .symbol = "i64.ne" } };
                pub const eq = Sexp{ .value = .{ .symbol = "i64.eq" } };
                pub const @"const" = Sexp{ .value = .{ .symbol = "i64.const" } };

                pub const extend_i32_s = Sexp{ .value = .{ .symbol = "i64.extend_i32_s" } };
                pub const extend_i32_u = Sexp{ .value = .{ .symbol = "i64.extend_i32_u" } };
            };

            pub const f32_ = struct {
                pub const add = Sexp{ .value = .{ .symbol = "f32.add" } };
                pub const sub = Sexp{ .value = .{ .symbol = "f32.sub" } };
                pub const mul = Sexp{ .value = .{ .symbol = "f32.mul" } };
                pub const div = Sexp{ .value = .{ .symbol = "f32.div" } };
                pub const rem = Sexp{ .value = .{ .symbol = "f32.rem" } };
                pub const gt = Sexp{ .value = .{ .symbol = "f32.gt" } };
                pub const ge = Sexp{ .value = .{ .symbol = "f32.ge" } };
                pub const lt = Sexp{ .value = .{ .symbol = "f32.lt" } };
                pub const le = Sexp{ .value = .{ .symbol = "f32.le" } };
                pub const ne = Sexp{ .value = .{ .symbol = "f32.ne" } };
                pub const eq = Sexp{ .value = .{ .symbol = "f32.eq" } };
                pub const @"const" = Sexp{ .value = .{ .symbol = "f32.const" } };

                pub const convert_i32_s = Sexp{ .value = .{ .symbol = "f32.convert_i32_s" } };
                pub const convert_i32_u = Sexp{ .value = .{ .symbol = "f32.convert_i32_u" } };
                pub const convert_i64_s = Sexp{ .value = .{ .symbol = "f32.convert_i64_s" } };
                pub const convert_i64_u = Sexp{ .value = .{ .symbol = "f32.convert_i64_u" } };
            };

            pub const f64_ = struct {
                pub const add = Sexp{ .value = .{ .symbol = "f64.add" } };
                pub const sub = Sexp{ .value = .{ .symbol = "f64.sub" } };
                pub const mul = Sexp{ .value = .{ .symbol = "f64.mul" } };
                pub const div = Sexp{ .value = .{ .symbol = "f64.div" } };
                pub const rem = Sexp{ .value = .{ .symbol = "f64.rem" } };
                pub const gt = Sexp{ .value = .{ .symbol = "f64.gt" } };
                pub const ge = Sexp{ .value = .{ .symbol = "f64.ge" } };
                pub const lt = Sexp{ .value = .{ .symbol = "f64.lt" } };
                pub const le = Sexp{ .value = .{ .symbol = "f64.le" } };
                pub const ne = Sexp{ .value = .{ .symbol = "f64.ne" } };
                pub const eq = Sexp{ .value = .{ .symbol = "f64.eq" } };
                pub const @"const" = Sexp{ .value = .{ .symbol = "f64.const" } };

                pub const convert_i32_s = Sexp{ .value = .{ .symbol = "f64.convert_i32_s" } };
                pub const convert_i32_u = Sexp{ .value = .{ .symbol = "f64.convert_i32_u" } };
                pub const convert_i64_s = Sexp{ .value = .{ .symbol = "f64.convert_i64_s" } };
                pub const convert_i64_u = Sexp{ .value = .{ .symbol = "f64.convert_i64_u" } };

                pub const promote_f32 = Sexp{ .value = .{ .symbol = "f64.promote_f32" } };
            };
        };

        // TODO: can I run a test that the names match the exports of intrinsics.zig?
        pub const intrinsics = struct {
            pub const max = .{
                .wasm_sym = Sexp{ .value = .{ .symbol = "$__grappl_max" } },
                .node_desc = builtin.builtin_nodes.max,
            };
            pub const min = .{
                .wasm_sym = Sexp{ .value = .{ .symbol = "$__grappl_min" } },
                .node_desc = builtin.builtin_nodes.min,
            };
            pub const string_indexof = .{
                .wasm_sym = Sexp{ .value = .{ .symbol = "$__grappl_string_indexof" } },
                .node_desc = builtin.builtin_nodes.string_indexof,
            };
            pub const string_len = .{
                .wasm_sym = Sexp{ .value = .{ .symbol = "$__grappl_string_len" } },
                .node_desc = builtin.builtin_nodes.string_length,
            };
            pub const string_equal = .{
                .wasm_sym = Sexp{ .value = .{ .symbol = "$__grappl_string_equal" } },
                .node_desc = builtin.builtin_nodes.string_equal,
            };
        };
    };

    fn finishCompileTypedFunc(self: *@This(), name: []const u8, func_decl: DeferredFuncDeclInfo, func_type: DeferredFuncTypeInfo) !void {
        const alloc = self.arena.allocator();

        const complete_func_type_desc = TypeInfo{
            .name = name,
            .func_type = .{
                .param_names = func_decl.param_names,
                .param_types = func_type.param_types,
                .local_names = func_decl.local_names,
                .local_types = func_decl.local_types,
                .result_names = func_decl.result_names,
                .result_types = func_type.result_types,
            },
        };

        const func_type_in_env = try self.env.addType(alloc, complete_func_type_desc);
        _ = func_type_in_env;

        {
            const export_sexp = try self.module_body.addOne();
            export_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try export_sexp.value.list.ensureTotalCapacityPrecise(3);
            export_sexp.value.list.addOneAssumeCapacity().* = wat_syms.@"export";
            export_sexp.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .borrowedString = complete_func_type_desc.name } };
            const export_val_sexp = export_sexp.value.list.addOneAssumeCapacity();

            export_val_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try export_val_sexp.value.list.ensureTotalCapacityPrecise(2);
            // 1 for "func", and 1 for result
            export_val_sexp.value.list.addOneAssumeCapacity().* = wat_syms.func;
            // FIXME: this leaks! symbols are assumed to be borrowed
            export_val_sexp.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "${s}", .{complete_func_type_desc.name}) } };
        }

        const result_type_sexp = _: {
            const type_sexp = try self.module_body.addOne();
            // FIXME: would be really nice to just have comptime sexp parsing...
            // or: Sexp.fromFormat("(+ {} 3)", .{sexp});
            type_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try type_sexp.value.list.ensureTotalCapacityPrecise(3);
            // TODO: static sexp pointers here
            type_sexp.value.list.addOneAssumeCapacity().* = wat_syms.type;
            type_sexp.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "$typeof_{s}", .{complete_func_type_desc.name}) } };
            const func_type_sexp = type_sexp.value.list.addOneAssumeCapacity();

            func_type_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            // 1 for "func", and 1 for result
            try func_type_sexp.value.list.ensureTotalCapacityPrecise(1 + complete_func_type_desc.func_type.?.param_types.len + 1);
            func_type_sexp.value.list.addOneAssumeCapacity().* = wat_syms.func;
            for (complete_func_type_desc.func_type.?.param_types) |param_type| {
                // FIXME: params are not in separate s-exp! it should be (param i32 i32 i32)
                const param_sexp = func_type_sexp.value.list.addOneAssumeCapacity();
                param_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try param_sexp.value.list.ensureTotalCapacityPrecise(2);
                param_sexp.value.list.addOneAssumeCapacity().* = wat_syms.param;
                param_sexp.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = param_type.name } };
            }

            const result_sexp = func_type_sexp.value.list.addOneAssumeCapacity();
            result_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try result_sexp.value.list.ensureTotalCapacityPrecise(2);
            result_sexp.value.list.addOneAssumeCapacity().* = wat_syms.result;
            // FIXME: compile return type
            break :_ result_sexp.value.list.addOneAssumeCapacity();
        };

        // FIXME: use addOneAssumeCapacity
        {
            const impl_sexp = try self.module_body.addOne();
            // FIXME: would be really nice to just have comptime sexp parsing...
            // or: Sexp.fromFormat("(+ {} 3)", .{sexp});
            impl_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            // TODO: static sexp pointers here
            (try impl_sexp.value.list.addOne()).* = wat_syms.func;
            // FIXME: this leaks! symbols are assumed to be borrowed!
            (try impl_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "${s}", .{complete_func_type_desc.name}) } };

            for (func_decl.param_names, complete_func_type_desc.func_type.?.param_types) |param_name, param_type| {
                const param_sexp = try impl_sexp.value.list.addOne();
                param_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try param_sexp.value.list.ensureTotalCapacityPrecise(3);
                (try param_sexp.value.list.addOne()).* = wat_syms.param;
                (try param_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "$param_{s}", .{param_name}) } };
                (try param_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = param_type.name } };
            }

            const result_sexp = try impl_sexp.value.list.addOne();
            result_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try result_sexp.value.list.ensureTotalCapacityPrecise(2);
            result_sexp.value.list.addOneAssumeCapacity().* = wat_syms.result;

            const result_type_sexp2 = result_sexp.value.list.addOneAssumeCapacity();

            // NOTE: if these are unmatched, it might mean a typeof for that local is missing
            for (func_decl.local_names, complete_func_type_desc.func_type.?.local_types) |local_name, local_type| {
                const local_sexp = try impl_sexp.value.list.addOne();
                local_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try local_sexp.value.list.ensureTotalCapacityPrecise(3);
                (try local_sexp.value.list.addOne()).* = wat_syms.local;
                (try local_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "$local_{s}", .{local_name}) } };
                (try local_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = local_type.name } };
            }

            std.debug.assert(func_decl.return_exprs.len >= 1);
            for (func_decl.return_exprs) |return_expr| {
                const body_fragment = try self.compileExpr(&return_expr, &.{
                    .local_names = func_decl.local_names,
                    .local_types = func_decl.local_types,
                    .param_names = func_decl.param_names,
                    .param_types = func_type.param_types,
                });
                // FIXME: this is a horrible way to do type resolution
                // FIXME: use known type symbol where possible (e.g. interning!)
                result_type_sexp.* = Sexp{ .value = .{ .symbol = body_fragment.resolved_type.name } };
                result_type_sexp2.* = result_type_sexp.*;
                std.debug.assert(func_type.result_types.len == 1);
                if (body_fragment.resolved_type != func_type.result_types[0]) {
                    std.log.warn("body_fragment:\n{}\n", .{Sexp{ .value = .{ .module = body_fragment.code } }});
                    std.log.warn("type: '{s}' doesn't match '{s}'", .{ body_fragment.resolved_type.name, func_type.result_types[0].name });
                    // FIXME/HACK: re-enable but disabling now to allow for type promotion
                    //return error.ReturnTypeMismatch;
                }

                // FIXME: what about the rest of the code?
                (try impl_sexp.value.list.addOne()).* = body_fragment.code.items[0];
            }
        }
    }

    /// A fragment of compiled code and the type of its final variable
    const Fragment = struct {
        code: std.ArrayList(Sexp),
        resolved_type: Type,

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            _ = alloc;
            self.code.deinit();
        }
    };

    fn resolvePeerTypesWithPromotions(self: *@This(), a: *Fragment, b: *Fragment) !Type {
        // REPORT: zig can't switch on constant pointers
        // return switch (a.resolved_type) {
        //     primitive_types.i32_ => switch (b.resolved_type) {
        //         primitive_types.i32_ => primitive_types.i32_,
        //         primitive_types.i64_ => primitive_types.i64_,
        //         primitive_types.f32_ => primitive_types.f32_,
        //         primitive_types.f64_ => primitive_types.f64_,
        //         else => @panic("unimplemented peer type resolution"),
        //     },
        //     primitive_types.i64_ => switch (b.resolved_type) {
        //         primitive_types.i32_ => primitive_types.i64_,
        //         primitive_types.i64_ => primitive_types.i64_,
        //         primitive_types.f32_ => primitive_types.f32_,
        //         primitive_types.f64_ => primitive_types.f64_,
        //         else => @panic("unimplemented peer type resolution"),
        //     },
        //     primitive_types.f32_ => switch (b.resolved_type) {
        //         primitive_types.i32_ => primitive_types.f32_,
        //         primitive_types.i64_ => primitive_types.f32_,
        //         primitive_types.f32_ => primitive_types.f32_,
        //         primitive_types.f64_ => primitive_types.f64_,
        //         else => @panic("unimplemented peer type resolution"),
        //     },
        //     primitive_types.f64_ => switch (b.resolved_type) {
        //         primitive_types.i32_ => primitive_types.f64_,
        //         primitive_types.i64_ => primitive_types.f64_,
        //         primitive_types.f32_ => primitive_types.f64_,
        //         primitive_types.f64_ => primitive_types.f64_,
        //         else => @panic("unimplemented peer type resolution"),
        //     },
        //     else => @panic("unimplemented peer type resolution"),
        // };

        if (a.resolved_type == builtin.empty_type)
            return b.resolved_type;

        if (b.resolved_type == builtin.empty_type)
            return a.resolved_type;

        const resolved_type = _: {
            if (a.resolved_type == primitive_types.i32_) {
                if (b.resolved_type == primitive_types.i32_) break :_ primitive_types.i32_;
                if (b.resolved_type == primitive_types.i64_) break :_ primitive_types.i64_;
                if (b.resolved_type == primitive_types.f32_) break :_ primitive_types.f32_;
                if (b.resolved_type == primitive_types.f64_) break :_ primitive_types.f64_;
            } else if (a.resolved_type == primitive_types.i64_) {
                if (b.resolved_type == primitive_types.i32_) break :_ primitive_types.i64_;
                if (b.resolved_type == primitive_types.i64_) break :_ primitive_types.i64_;
                if (b.resolved_type == primitive_types.f32_) break :_ primitive_types.f32_;
                if (b.resolved_type == primitive_types.f64_) break :_ primitive_types.f64_;
            } else if (a.resolved_type == primitive_types.f32_) {
                if (b.resolved_type == primitive_types.i32_) break :_ primitive_types.f32_;
                if (b.resolved_type == primitive_types.i64_) break :_ primitive_types.f32_;
                if (b.resolved_type == primitive_types.f32_) break :_ primitive_types.f32_;
                if (b.resolved_type == primitive_types.f64_) break :_ primitive_types.f64_;
            } else if (a.resolved_type == primitive_types.f64_) {
                if (b.resolved_type == primitive_types.i32_) break :_ primitive_types.f64_;
                if (b.resolved_type == primitive_types.i64_) break :_ primitive_types.f64_;
                if (b.resolved_type == primitive_types.f32_) break :_ primitive_types.f64_;
                if (b.resolved_type == primitive_types.f64_) break :_ primitive_types.f64_;
            }
            std.log.err("unimplemented peer type resolution: {s} & {s}", .{ a.resolved_type.name, b.resolved_type.name });
            std.debug.panic("unimplemented peer type resolution: {s} & {s}", .{ a.resolved_type.name, b.resolved_type.name });
        };

        const alloc = self.arena.allocator();

        inline for (&.{ a, b }) |fragment| {
            var i: usize = 0;
            const MAX_ITERS = 128;
            while (fragment.resolved_type != resolved_type) : (i += 1) {
                if (i > MAX_ITERS) {
                    std.debug.panic("max iters resolving types: {s} -> {s}", .{ fragment.resolved_type.name, resolved_type.name });
                }

                std.debug.assert(fragment.code.items.len == 1);

                const prev = fragment.code.items[0];
                fragment.code.items[0] = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try fragment.code.items[0].value.list.ensureTotalCapacityPrecise(2);
                const converter = fragment.code.items[0].value.list.addOneAssumeCapacity();
                fragment.code.items[0].value.list.addOneAssumeCapacity().* = prev;

                if (fragment.resolved_type == primitive_types.i32_) {
                    converter.* = wat_syms.ops.i64_.extend_i32_s;
                    fragment.resolved_type = primitive_types.i64_;
                } else if (fragment.resolved_type == primitive_types.i64_) {
                    converter.* = wat_syms.ops.f32_.convert_i64_s;
                    fragment.resolved_type = primitive_types.f32_;
                } else if (fragment.resolved_type == primitive_types.u32_) {
                    converter.* = wat_syms.ops.i64_.extend_i32_u;
                    fragment.resolved_type = primitive_types.i64_;
                } else if (fragment.resolved_type == primitive_types.u64_) {
                    converter.* = wat_syms.ops.f32_.convert_i64_u;
                    fragment.resolved_type = primitive_types.f32_;
                } else if (fragment.resolved_type == primitive_types.f32_) {
                    converter.* = wat_syms.ops.f64_.promote_f32;
                    fragment.resolved_type = primitive_types.f64_;
                } else if (fragment.resolved_type == primitive_types.f64_) {
                    unreachable; // currently can't resolve higher than this
                } else {
                    std.log.err("unimplemented type promotion: {s} -> {s}", .{ fragment.resolved_type.name, resolved_type.name });
                    std.debug.panic("unimplemented type promotion: {s} -> {s}", .{ fragment.resolved_type.name, resolved_type.name });
                }
            }
        }

        return resolved_type;
    }

    /// adds global data, returns a unique name
    fn addReadonlyData(self: *@This(), data: []const u8) !usize {
        const alloc = self.arena.allocator();
        //(data $.rodata (i32.const 1048576) "\04\00\10\00hello\00"))
        const mod_forms = &self.wat.value.module.items[0].value.list;
        const data_form = try mod_forms.addOne();
        data_form.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
        try data_form.value.list.ensureTotalCapacityPrecise(3);

        data_form.value.list.addOneAssumeCapacity().* = wat_syms.data;
        const offset_spec = data_form.value.list.addOneAssumeCapacity();

        var data_str = std.ArrayList(u8).init(alloc);
        defer data_str.deinit();
        // maximum, as if every byte were replaced with '\00'
        try data_str.ensureTotalCapacity(data.len * 3);
        std.debug.assert(zig_builtin.cpu.arch.endian() == .little);
        try writeWasmMemoryString(std.mem.asBytes(&data.len), data_str.writer());
        try writeWasmMemoryString(data, data_str.writer());

        data_form.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{
            .ownedString = try data_str.toOwnedSlice(),
        } };

        offset_spec.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
        try offset_spec.value.list.ensureTotalCapacityPrecise(2);
        offset_spec.value.list.addOneAssumeCapacity().* = wat_syms.ops.i32_.@"const";
        offset_spec.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = @intCast(self.next_global_data_ptr) } };
        const prev_global_data_ptr = self.next_global_data_ptr;
        self.next_global_data_ptr += data.len;
        errdefer self.next_global_data_ptr = prev_global_data_ptr;

        return prev_global_data_ptr;
    }

    // TODO: take a diagnostic
    fn compileExpr(
        self: *@This(),
        code_sexp: *const Sexp,
        context: *const struct {
            local_names: []const []const u8,
            local_types: []const Type,
            param_names: []const []const u8,
            param_types: []const Type,
        },
    ) !Fragment {
        const alloc = self.arena.allocator();
        switch (code_sexp.value) {
            .list => |v| {
                std.debug.assert(v.items.len >= 1);
                const func = &v.items[0];
                std.debug.assert(func.value == .symbol);

                var result = Fragment{
                    .code = std.ArrayList(Sexp).init(alloc),
                    .resolved_type = builtin.empty_type,
                };

                // HACK: super terrible starting macro impl wowowWWW
                if (func.value.symbol.ptr == syms.json_quote.value.symbol.ptr) {
                    std.debug.assert(v.items.len == 2);

                    var bytes = std.ArrayList(u8).init(alloc);
                    defer bytes.deinit();
                    // TODO: json shenanigans
                    try bytes.writer().print("{}", .{v.items[1]});

                    const data_offset = try self.addReadonlyData(bytes.items);

                    try result.code.ensureTotalCapacityPrecise(1);
                    const wasm_op = result.code.addOneAssumeCapacity();
                    wasm_op.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                    try wasm_op.value.list.ensureTotalCapacityPrecise(2);
                    wasm_op.value.list.addOneAssumeCapacity().* = wat_syms.ops.i32_.@"const";
                    wasm_op.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = @intCast(data_offset) } };

                    return result;
                }

                const arg_fragments = try alloc.alloc(Fragment, v.items.len - 1);
                // FIXME: don't deinit!
                //defer for (arg_fragments) |*frag| frag.deinit(alloc);
                defer alloc.free(arg_fragments);

                for (v.items[1..], arg_fragments) |arg_src, *arg_fragment| {
                    arg_fragment.* = try self.compileExpr(&arg_src, context);
                }

                if (func.value.symbol.ptr == syms.@"return".value.symbol.ptr) {
                    // FIXME:
                    try result.code.ensureUnusedCapacity(v.items.len - 1);
                    for (v.items[1..]) |*return_expr| {
                        var compiled = try self.compileExpr(return_expr, context);
                        result.resolved_type = try self.resolvePeerTypesWithPromotions(&result, &compiled);
                        try result.code.appendSlice(try compiled.code.toOwnedSlice());
                    }

                    return result;
                }

                if (func.value.symbol.ptr == syms.@"set!".value.symbol.ptr) {
                    std.debug.assert(arg_fragments.len == 2);

                    std.debug.assert(arg_fragments[0].code.items.len == 1);
                    std.debug.assert(arg_fragments[0].code.items[0].value == .list);
                    std.debug.assert(arg_fragments[0].code.items[0].value.list.items.len == 2);
                    std.debug.assert(arg_fragments[0].code.items[0].value.list.items[0].value == .symbol);
                    std.debug.assert(arg_fragments[0].code.items[0].value.list.items[1].value == .symbol);

                    result.resolved_type = try self.resolvePeerTypesWithPromotions(&arg_fragments[0], &arg_fragments[1]);

                    // FIXME: leak
                    const set_sym = arg_fragments[0].code.items[0].value.list.items[1];

                    std.debug.assert(arg_fragments[1].code.items.len == 1);
                    const set_val = arg_fragments[1].code.items[0];

                    try result.code.ensureTotalCapacityPrecise(1);
                    const wasm_op = result.code.addOneAssumeCapacity();
                    wasm_op.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                    try wasm_op.value.list.ensureTotalCapacityPrecise(3);
                    wasm_op.value.list.addOneAssumeCapacity().* = wat_syms.ops.@"local.set";

                    wasm_op.value.list.addOneAssumeCapacity().* = set_sym;
                    // TODO: more idiomatic move out data
                    arg_fragments[0].code.items[0] = Sexp{ .value = .void };

                    wasm_op.value.list.addOneAssumeCapacity().* = set_val;
                    // TODO: more idiomatic move out data
                    arg_fragments[1].code.items[0] = Sexp{ .value = .void };

                    return result;
                }

                // arithmetic builtins
                inline for (&.{
                    .{
                        .sym = syms.@"+",
                        .wasm_name = "add",
                    },
                    .{
                        .sym = syms.@"-",
                        .wasm_name = "sub",
                    },
                    .{
                        .sym = syms.@"*",
                        .wasm_name = "mul",
                    },
                    .{
                        .sym = syms.@"/",
                        .wasm_name = "div",
                    },
                    // FIXME: need to support unsigned and signed!
                    .{
                        .sym = syms.@"==",
                        .wasm_name = "eq",
                    },
                    .{
                        .sym = syms.@"!=",
                        .wasm_name = "ne",
                    },
                    .{
                        .sym = syms.@"<",
                        .wasm_name = "lt",
                    },
                    .{
                        .sym = syms.@"<=",
                        .wasm_name = "le",
                    },
                    .{
                        .sym = syms.@">",
                        .wasm_name = "gt",
                    },
                    .{
                        .sym = syms.@">=",
                        .wasm_name = "ge",
                    },
                }) |builtin_op| {
                    if (func.value.symbol.ptr == builtin_op.sym.value.symbol.ptr) {
                        try result.code.ensureTotalCapacityPrecise(1);
                        const wasm_op = result.code.addOneAssumeCapacity();
                        wasm_op.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                        try wasm_op.value.list.ensureTotalCapacityPrecise(3);
                        const op_name = wasm_op.value.list.addOneAssumeCapacity();

                        std.debug.assert(arg_fragments.len == 2);
                        for (arg_fragments) |*arg_fragment| {
                            result.resolved_type = try self.resolvePeerTypesWithPromotions(&result, arg_fragment);
                            std.debug.assert(arg_fragment.code.items.len == 1);
                            // resolve peer types could have mutated it
                            (try wasm_op.value.list.addOne()).* = arg_fragment.code.items[0];
                            // TODO: more idiomatic move out data
                            arg_fragment.code.items[0] = Sexp{ .value = .void };
                        }

                        var handled = false;

                        inline for (&.{ "i32_", "i64_", "f32_", "f64_" }) |type_name| {
                            const primitive_type: Type = @field(primitive_types, type_name);
                            if (result.resolved_type == primitive_type) {
                                const wasm_type_ops = @field(wat_syms.ops, type_name);
                                op_name.* = @field(wasm_type_ops, builtin_op.wasm_name);
                                handled = true;
                            }
                        }

                        // REPORT ME: try to prefer an else on the above for loop, currently couldn't get it to compile right
                        if (!handled) {
                            std.log.err("unimplemented type resolution: '{s}'", .{result.resolved_type.name});
                            std.debug.panic("unimplemented type resolution: '{s}'", .{result.resolved_type.name});
                        }

                        return result;
                    }
                }

                // builtins with intrinsics
                inline for (comptime std.meta.declarations(wat_syms.intrinsics)) |intrinsic_decl| {
                    const intrinsic = @field(wat_syms.intrinsics, intrinsic_decl.name);
                    const node_desc = intrinsic.node_desc;
                    const outputs = node_desc.getOutputs();
                    std.debug.assert(outputs.len == 1);
                    std.debug.assert(outputs[0].kind == .primitive);
                    std.debug.assert(outputs[0].kind.primitive == .value);
                    result.resolved_type = outputs[0].kind.primitive.value;

                    if (func.value.symbol.ptr == node_desc.name().ptr) {
                        try result.code.ensureTotalCapacityPrecise(1);
                        const wasm_call = result.code.addOneAssumeCapacity();
                        wasm_call.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                        try wasm_call.value.list.ensureTotalCapacityPrecise(2 + arg_fragments.len);
                        // FIXME: use types to determine
                        wasm_call.value.list.addOneAssumeCapacity().* = wat_syms.call;
                        wasm_call.value.list.addOneAssumeCapacity().* = intrinsic.wasm_sym;

                        for (arg_fragments) |arg_fragment| {
                            std.debug.assert(arg_fragment.code.items.len == 1);
                            wasm_call.value.list.addOneAssumeCapacity().* = arg_fragment.code.items[0];
                            // move out
                            arg_fragment.code.items[0] = Sexp{ .value = .void };
                        }

                        return result;
                    }
                }

                // call (host?) functions
                const func_node_desc = self.env.nodes.get(func.value.symbol) orelse {
                    std.log.err("undefined symbol1: '{}'\n", .{func});
                    return error.UndefinedSymbol;
                };

                {
                    const outputs = func_node_desc.getOutputs();
                    result.resolved_type = if (outputs.len >= 1 and outputs[0].kind == .primitive and outputs[0].kind.primitive == .value)
                        outputs[0].kind.primitive.value
                        // FIXME: bad type resolution for void returning functions
                    else
                        primitive_types.i32_;

                    try result.code.ensureTotalCapacityPrecise(1);
                    const wasm_call = result.code.addOneAssumeCapacity();
                    wasm_call.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                    try wasm_call.value.list.ensureTotalCapacityPrecise(2 + arg_fragments.len);
                    // FIXME: use types to determine
                    wasm_call.value.list.addOneAssumeCapacity().* = wat_syms.call;
                    // FIXME: leak
                    wasm_call.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "${s}", .{func.value.symbol}) } };

                    for (arg_fragments) |arg_fragment| {
                        std.debug.assert(arg_fragment.code.items.len == 1);
                        wasm_call.value.list.addOneAssumeCapacity().* = arg_fragment.code.items[0];
                        // move out
                        arg_fragment.code.items[0] = Sexp{ .value = .void };
                    }

                    return result;
                }

                // otherwise we have a non builtin
                std.log.err("unhandled call: {}", .{code_sexp});
                return error.UnhandledCall;
            },

            .int => |v| {
                var result = Fragment{
                    .code = std.ArrayList(Sexp).init(alloc),
                    .resolved_type = builtin.primitive_types.i32_,
                };

                try result.code.ensureTotalCapacityPrecise(1);
                const wasm_const = result.code.addOneAssumeCapacity();
                wasm_const.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try wasm_const.value.list.ensureTotalCapacityPrecise(2);

                // FIXME: have a type context
                wasm_const.value.list.addOneAssumeCapacity().* = wat_syms.ops.i32_.@"const";
                wasm_const.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = v } };

                return result;
            },

            .float => |v| {
                var result = Fragment{
                    .code = std.ArrayList(Sexp).init(alloc),
                    .resolved_type = builtin.primitive_types.f64_,
                };

                try result.code.ensureTotalCapacityPrecise(1);
                const wasm_const = result.code.addOneAssumeCapacity();
                wasm_const.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try wasm_const.value.list.ensureTotalCapacityPrecise(2);
                wasm_const.value.list.addOneAssumeCapacity().* = wat_syms.ops.f64_.@"const";
                wasm_const.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .float = v } };

                return result;
            },

            .symbol => |v| {
                // FIXME: use hashmap instead
                const Info = struct {
                    resolved_type: builtin.Type,
                    ref: []const u8,
                };

                const info = _: {
                    for (context.local_names, context.local_types) |local_name, local_type| {
                        if (std.mem.eql(u8, v, local_name)) {
                            break :_ Info{ .resolved_type = local_type, .ref = try std.fmt.allocPrint(alloc, "$local_{s}", .{v}) };
                        }
                    }

                    for (context.param_names, context.param_types) |param_name, param_type| {
                        if (std.mem.eql(u8, v, param_name)) {
                            break :_ Info{ .resolved_type = param_type, .ref = try std.fmt.allocPrint(alloc, "$param_{s}", .{v}) };
                        }
                    }

                    std.log.err("undefined symbol2: '{s}'", .{v});
                    return error.UndefinedSymbol;
                };

                var result = Fragment{
                    .code = std.ArrayList(Sexp).init(alloc),
                    .resolved_type = info.resolved_type,
                };

                try result.code.ensureTotalCapacityPrecise(1);
                const wasm_local_get = result.code.addOneAssumeCapacity();
                wasm_local_get.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try wasm_local_get.value.list.ensureTotalCapacityPrecise(2);
                wasm_local_get.value.list.addOneAssumeCapacity().* = wat_syms.ops.@"local.get";
                // FIXME: leak
                wasm_local_get.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{
                    .symbol = info.ref,
                } };

                return result;
            },

            inline else => {
                std.log.err("unimplemented expr for compilation:\n{}\n", .{code_sexp});
                std.debug.panic("unimplemented type: '{s}'", .{@tagName(code_sexp.value)});
            },
        }
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

    pub fn compileModule(self: *@This(), sexp: *const Sexp) ![]const u8 {
        std.debug.assert(sexp.value == .module);

        const alloc = self.arena.allocator();

        // set these since they are inited to undefined
        self.env = try Env.initDefault(self.arena.allocator());
        self.wat = Sexp{ .value = .{ .module = std.ArrayList(Sexp).init(self.arena.allocator()) } };
        try self.wat.value.module.ensureTotalCapacityPrecise(1);
        const module_body = self.wat.value.module.addOneAssumeCapacity();
        module_body.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.arena.allocator()) } };
        self.module_body = &module_body.value.list;
        try self.module_body.ensureTotalCapacity(5);
        self.module_body.addOneAssumeCapacity().* = wat_syms.module;

        // add user funcs to env
        {
            var maybe_cursor = self.user_context.funcs.first;
            while (maybe_cursor) |cursor| : (maybe_cursor = cursor.next) {
                _ = try self.env.addNode(alloc, builtin.basicMutableNode(&cursor.data));
            }
        }

        // imports
        {
            var host_callbacks_prologue = try SexpParser.parse(alloc,
                \\(func $callUserFunc_JSON_R_JSON (import "env" "callUserFunc_JSON_R_JSON") (param i32) (param i32) (param i32) (result i32) (result i32))
                \\(func $callUserFunc_R_void (import "env" "callUserFunc_R_void") (param i32))
                \\(func $callUserFunc_i32_R_void (import "env" "callUserFunc_i32_R_void") (param i32) (param i32))
                \\(func $callUserFunc_i32_R_i32 (import "env" "callUserFunc_i32_R_i32") (param i32) (param i32) (result i32))
                \\(func $callUserFunc_i32_i32_R_i32 (import "env" "callUserFunc_i32_i32_R_i32") (param i32) (param i32) (param i32) (result i32))
            , null);
            try self.module_body.appendSlice(try host_callbacks_prologue.value.module.toOwnedSlice());
        }

        {
            const memory = self.module_body.addOneAssumeCapacity();
            memory.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.arena.allocator()) } };
            try memory.value.list.ensureTotalCapacityPrecise(3);
            memory.value.list.addOneAssumeCapacity().* = wat_syms.memory;
            memory.value.list.addOneAssumeCapacity().* = wat_syms.@"$0";
            memory.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = 0 } };
        }

        {
            // TODO: export helper
            const memory_export = self.module_body.addOneAssumeCapacity();
            memory_export.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.arena.allocator()) } };
            try memory_export.value.list.ensureTotalCapacityPrecise(3);
            memory_export.value.list.addOneAssumeCapacity().* = wat_syms.@"export";
            memory_export.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .borrowedString = "memory" } };
            const memory_export_val = memory_export.value.list.addOneAssumeCapacity();
            memory_export_val.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.arena.allocator()) } };
            try memory_export_val.value.list.ensureTotalCapacityPrecise(2);
            memory_export_val.value.list.addOneAssumeCapacity().* = wat_syms.memory;
            memory_export_val.value.list.addOneAssumeCapacity().* = wat_syms.@"$0";
        }

        // thunks for user provided functions
        {
            // TODO/NEXT: for each user provided function, build a thunk and append it
            var maybe_user_func = self.user_context.funcs.first;
            while (maybe_user_func) |user_func| : (maybe_user_func = user_func.next) {
                if (user_func.data.inputs.len == 2
                //
                and user_func.data.inputs[1].kind == .primitive
                //
                and user_func.data.inputs[1].kind.primitive == .value
                //
                and user_func.data.inputs[1].kind.primitive.value == primitive_types.i32_) {
                    // TODO: create dedicated function for this kind of substitution
                    const user_func_thunk_src = try std.fmt.allocPrint(alloc,
                        \\(func ${s}
                        \\      (param $param_1 i32)
                        \\      (call $callUserFunc_i32_R_void (i32.const {}) (local.get $param_1)))
                    , .{ user_func.data.name, @intFromPtr(&user_func.data) });
                    var user_func_thunk = try SexpParser.parse(alloc, user_func_thunk_src, null);
                    defer user_func_thunk.deinit(alloc);
                    try self.module_body.appendSlice(try user_func_thunk.value.module.toOwnedSlice());
                    // } else if (user_func.data.inputs.len == 2
                    // //
                    // and user_func.data.inputs[1].kind == .primitive
                    // //
                    // and user_func.data.inputs[1].kind.primitive == .value
                    // //
                    // and user_func.data.inputs[1].kind.primitive.value == primitive_types.i32_) {
                    //     // TODO: create dedicated function for this kind of substitution
                    //     const user_func_thunk_src = try std.fmt.allocPrint(alloc,
                    //         \\(func ${s}
                    //         \\      (param $in_ptr i32)
                    //         \\      (param $in_len i32)
                    //         \\      (result $in_ptr i32)
                    //         \\      (result $in_len i32)
                    //         \\      (local $out_ptr i32)
                    //         \\      (local $out_len i32)
                    //         \\      (call $callUserFunc_JSON_R_JSON (i32.const {}) (local.get $in_ptr) (local.get $in_len))
                    //         \\      (local.set $out_ptr)
                    //         \\      (local.set $out_len)
                    //         \\)
                    //     , .{ user_func.data.name, @intFromPtr(&user_func.data) });
                    //     var user_func_thunk = try SexpParser.parse(alloc, user_func_thunk_src, null);
                    //     defer user_func_thunk.deinit(alloc);
                    //     try self.module_body.appendSlice(try user_func_thunk.value.module.toOwnedSlice());
                } else if (user_func.data.inputs.len == 2
                //
                and user_func.data.inputs[1].kind == .primitive
                //
                and user_func.data.inputs[1].kind.primitive == .value
                //
                and user_func.data.inputs[1].kind.primitive.value == primitive_types.string) {
                    // TODO: create dedicated function for this kind of substitution
                    const user_func_thunk_src = try std.fmt.allocPrint(alloc,
                        \\(func ${s}
                        \\      (param $in_ptr i32)
                        \\      (param $in_len i32)
                        \\      (result $out_ptr i32)
                        \\      (result $out_len i32)
                        \\      (call $callUserFunc_string_R_string (i32.const {}) (local.get $in_ptr) (local.get $in_len))
                        \\      (local.set $out_ptr)
                        \\      (local.set $out_len)
                        \\)
                    , .{ user_func.data.name, @intFromPtr(&user_func.data) });
                    var user_func_thunk = try SexpParser.parse(alloc, user_func_thunk_src, null);
                    defer user_func_thunk.deinit(alloc);
                    try self.module_body.appendSlice(try user_func_thunk.value.module.toOwnedSlice());
                } else {
                    std.debug.panic("unhandled user_func type: {s}", .{user_func.data.name});
                }
            }
        }

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

        var bytes = std.ArrayList(u8).init(self.arena.allocator());
        defer bytes.deinit();
        const buffer_writer = bytes.writer();

        // FIXME: performantly parse the wat at compile time or use wasm merge
        // I don't trust my parser yet
        try bytes.appendSlice("(module\n");
        // FIXME: HACK: merge these properly...
        const without_mod_wrapper = intrinsics_code;
        try bytes.appendSlice(without_mod_wrapper);
        try bytes.appendSlice("\n");
        // FIXME: come up with a way to just say assert(self.wat.like("(module"))
        std.debug.assert(self.wat.value == .module);
        std.debug.assert(self.wat.value.module.items.len == 1);
        std.debug.assert(self.wat.value.module.items[0].value == .list);
        std.debug.assert(self.wat.value.module.items[0].value.list.items.len >= 1);
        std.debug.assert(self.wat.value.module.items[0].value.list.items[0].value == .symbol);
        std.debug.assert(self.wat.value.module.items[0].value.list.items[0].value.symbol.ptr == wat_syms.module.value.symbol.ptr);
        const module_contents = self.wat.value.module.items[0].value.list.items[1..];

        for (module_contents) |toplevel| {
            _ = try toplevel.write(buffer_writer);
            try bytes.appendSlice("\n");
        }
        try bytes.appendSlice(")");

        // use arena parent so that when the arena deinit's, this remains,
        // and the caller can own the memory
        return try self.arena.child_allocator.dupe(u8, bytes.items);
    }
};

pub fn compile(
    a: std.mem.Allocator,
    sexp: *const Sexp,
    user_funcs: ?*std.SinglyLinkedList(builtin.BasicMutNodeDesc),
    _in_diagnostic: ?*Diagnostic,
) ![]const u8 {
    var ignored_diagnostic: Diagnostic = undefined; // FIXME: why don't we init?
    const diag = if (_in_diagnostic) |d| d else &ignored_diagnostic;
    diag.module = sexp;

    var unit = try Compilation.init(a, user_funcs, diag);
    defer unit.deinit();

    return unit.compileModule(sexp);
}

const t = std.testing;
const SexpParser = @import("./sexp_parser.zig").Parser;

test "parse" {
    // FIXME: support expression functions
    //     \\(define (++ x) (+ x 1))

    var user_funcs = std.SinglyLinkedList(builtin.BasicMutNodeDesc){};
    const user_func_1 = try t.allocator.create(std.SinglyLinkedList(builtin.BasicMutNodeDesc).Node);
    user_func_1.* = std.SinglyLinkedList(builtin.BasicMutNodeDesc).Node{
        .data = .{
            .name = "Confetti",
            .inputs = try t.allocator.dupe(builtin.Pin, &.{
                builtin.Pin{ .name = "exec", .kind = .{ .primitive = .exec } },
                builtin.Pin{
                    .name = "particleCount",
                    .kind = .{ .primitive = .{ .value = primitive_types.i32_ } },
                },
            }),
            .outputs = try t.allocator.dupe(builtin.Pin, &.{
                builtin.Pin{ .name = "", .kind = .{ .primitive = .exec } },
            }),
        },
    };
    defer t.allocator.destroy(user_func_1);
    defer t.allocator.free(user_func_1.data.inputs);
    defer t.allocator.free(user_func_1.data.outputs);
    user_funcs.prepend(user_func_1);

    var parsed = try SexpParser.parse(t.allocator,
        \\;;; comment
        \\(typeof g i64)
        \\(define g 10)
        \\
        \\;;; comment
        \\(typeof (++ i64) i64)
        \\(define (++ x)
        \\  (begin
        \\    (typeof a i64)
        \\    (define a 2)
        \\    (quote (+ f 1))
        \\    (quote (- f (* 2 3)))
        \\    (set! a 1)
        \\    (Confetti 100)
        \\    (return (max x a))))
        \\
        \\;;; comment
        \\(typeof (deep f32 f32) f32)
        \\(define (deep a b)
        \\  (begin
        \\    (return (+ (/ a 10) (* a b)))))
    , null);
    //std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit(t.allocator);

    const expected = try std.fmt.allocPrint(t.allocator,
        \\(module
        \\{s}
        \\(func $callUserFunc_JSON_R_JSON
        \\      (import "env"
        \\              "callUserFunc_JSON_R_JSON")
        \\      (param i32)
        \\      (param i32)
        \\      (param i32)
        \\      (result i32)
        \\      (result i32))
        \\(func $callUserFunc_R_void
        \\      (import "env"
        \\              "callUserFunc_R_void")
        \\      (param i32))
        \\(func $callUserFunc_i32_R_void
        \\      (import "env"
        \\              "callUserFunc_i32_R_void")
        \\      (param i32)
        \\      (param i32))
        \\(func $callUserFunc_i32_R_i32
        \\      (import "env"
        \\              "callUserFunc_i32_R_i32")
        \\      (param i32)
        \\      (param i32)
        \\      (result i32))
        \\(func $callUserFunc_i32_i32_R_i32
        \\      (import "env"
        \\              "callUserFunc_i32_i32_R_i32")
        \\      (param i32)
        \\      (param i32)
        \\      (param i32)
        \\      (result i32))
        \\(memory $0
        \\        0)
        \\(export "memory"
        \\        (memory $0))
        \\(func $Confetti
        \\      (param $param_1
        \\             i32)
        \\      (call $callUserFunc_i32_R_void
        \\            (i32.const {})
        \\            (local.get $param_1)))
        \\(export "++"
        \\        (func $++))
        \\(type $typeof_++
        \\      (func (param i64)
        \\            (result i32)))
        \\(func $++
        \\      (param $param_x
        \\             i64)
        \\      (result i32)
        \\      (local $local_a
        \\             i64)
        \\      (i32.const 0)
        \\      (i32.const 10)
        \\      (local.set $local_a
        \\                 (i64.extend_i32_s (i32.const 1)))
        \\      (call $Confetti
        \\            (i32.const 100))
        \\      (call $__grappl_max
        \\            (local.get $param_x)
        \\            (local.get $local_a)))
        \\(data (i32.const 0)
        \\      "\0a\00\00\00\00\00\00\00(+ f\0a   1)")
        \\(data (i32.const 10)
        \\      "\16\00\00\00\00\00\00\00(- f\0a   (* 2\0a      3))")
        \\(export "deep"
        \\        (func $deep))
        \\(type $typeof_deep
        \\      (func (param f32)
        \\            (param f32)
        \\            (result f32)))
        \\(func $deep
        \\      (param $param_a
        \\             f32)
        \\      (param $param_b
        \\             f32)
        \\      (result f32)
        \\      (f32.add (f32.div (local.get $param_a)
        \\                        (f32.convert_i64_s (i64.extend_i32_s (i32.const 10))))
        \\               (f32.mul (local.get $param_a)
        \\                        (local.get $param_b))))
        \\)
        // TODO: clearly instead of embedding the pointer we should have a global variable
        // so the host can set that
    , .{ intrinsics_code, @intFromPtr(&user_func_1.data) });
    defer t.allocator.free(expected);

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &user_funcs, &diagnostic)) |wat| {
        try t.expectEqualStrings(expected, wat);
        t.allocator.free(wat);
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}
