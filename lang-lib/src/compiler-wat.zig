//!
//! NOTE:
//! - probably would be better long term to use binaryen directly, it will have
//!   a more performant in-memory IR
//! - functions starting with ";" will cause a multiline comment, which is an example
//!   of small problems with this code not conforming to WAT precisely
//!

const zig_builtin = @import("builtin");
const build_opts = @import("build_opts");
const std = @import("std");
const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;
const primitive_type_syms = @import("./sexp.zig").primitive_type_syms;
const builtin = @import("./nodes/builtin.zig");
const primitive_types = @import("./nodes/builtin.zig").primitive_types;
const Env = @import("./nodes//builtin.zig").Env;
const TypeInfo = @import("./nodes//builtin.zig").TypeInfo;
const Type = @import("./nodes/builtin.zig").Type;

const intrinsics = @import("./intrinsics.zig");
const intrinsics_raw = @embedFile("grappl_intrinsics");
const intrinsics_code = intrinsics_raw["(module $grappl_intrinsics.wasm\n".len .. intrinsics_raw.len - 2];

pub const Diagnostic = struct {
    err: Error = .None,

    // set by compile call
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

    pub fn format(
        self: @This(),
        comptime fmt_str: []const u8,
        fmt_opts: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        // TODO: use contextualize
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

var empty_user_funcs = std.SinglyLinkedList(UserFunc){};

fn writeWasmMemoryString(data: []const u8, writer: anytype) !void {
    for (data) |char| {
        switch (char) {
            '\\' => {
                try writer.writeAll("\\\\");
            },
            // printable ascii not including '\\' or '"'
            ' '...'"' - 1, '"' + 1...'\\' - 1, '\\' + 1...127 => {
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

pub const UserFunc = struct {
    id: usize,
    node: builtin.BasicMutNodeDesc,
};

const Compilation = struct {
    /// will be edited during compilation as functions are discovered
    env: *Env,
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
        funcs: *std.SinglyLinkedList(UserFunc),
    },
    diag: *Diagnostic,

    next_global_data_ptr: usize = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        env: *Env,
        user_funcs: ?*std.SinglyLinkedList(UserFunc),
        in_diag: *Diagnostic,
    ) !@This() {
        const result = @This(){
            .arena = std.heap.ArenaAllocator.init(alloc),
            .diag = in_diag,
            .env = env,
            // FIXME: these are set in the main public entry, once we know
            // the caller has settled on where they are putting this object
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
                (try local_types.addOne()).* = self.env.getType(local_type.value.symbol) orelse return error.TypeNotFound;
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
            .body_exprs = return_exprs,
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
            type_.* = self.env.getType(param_type) orelse return error.UnknownType;
        }

        const result_types = try alloc.alloc(Type, 1);
        errdefer alloc.free(result_types);
        result_types[0] = self.env.getType(result_type_name) orelse return error.UnknownType;

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
        pub const then = Sexp{ .value = .{ .symbol = "then" } };
        pub const @"else" = Sexp{ .value = .{ .symbol = "else" } };

        pub const ops = struct {
            pub const @"local.get" = Sexp{ .value = .{ .symbol = "local.get" } };
            pub const @"local.set" = Sexp{ .value = .{ .symbol = "local.set" } };

            pub const i32_ = struct {
                pub const self = Sexp{ .value = .{ .symbol = "i32" } };
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
                pub const @"and" = Sexp{ .value = .{ .symbol = "i32.and" } };
                pub const @"or" = Sexp{ .value = .{ .symbol = "i32.or" } };
                pub const xor = Sexp{ .value = .{ .symbol = "i32.xor" } };
                pub const @"const" = Sexp{ .value = .{ .symbol = "i32.const" } };
            };

            pub const u32_ = struct {
                pub const self = Sexp{ .value = .{ .symbol = "u32" } };
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
                pub const @"and" = Sexp{ .value = .{ .symbol = "i32.and" } };
                pub const @"or" = Sexp{ .value = .{ .symbol = "i32.or" } };
                pub const xor = Sexp{ .value = .{ .symbol = "i32.xor" } };
                pub const @"const" = Sexp{ .value = .{ .symbol = "i32.const" } };
            };

            pub const i64_ = struct {
                pub const self = Sexp{ .value = .{ .symbol = "i64" } };
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
                pub const @"and" = Sexp{ .value = .{ .symbol = "i64.and" } };
                pub const @"or" = Sexp{ .value = .{ .symbol = "i64.or" } };
                pub const xor = Sexp{ .value = .{ .symbol = "i64.xor" } };
                pub const @"const" = Sexp{ .value = .{ .symbol = "i64.const" } };

                pub const extend_i32_s = Sexp{ .value = .{ .symbol = "i64.extend_i32_s" } };
                pub const extend_i32_u = Sexp{ .value = .{ .symbol = "i64.extend_i32_u" } };
            };

            pub const u64_ = struct {
                pub const self = Sexp{ .value = .{ .symbol = "u64" } };
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
                pub const self = Sexp{ .value = .{ .symbol = "f32" } };
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
                pub const self = Sexp{ .value = .{ .symbol = "f64" } };
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
            pub const string_concat = .{
                .wasm_sym = Sexp{ .value = .{ .symbol = "$__grappl_string_concat" } },
                .node_desc = builtin.builtin_nodes.string_concat,
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

        // TODO: do this earlier to prevent requiring order
        // FIXME: separate non-arena alloc
        // TODO: document need to pass env allocator
        // _ = try self.env.addNode(self.arena.child_allocator, builtin.basicNode(.{
        //     .name = name,
        //     .inputs =
        // }));

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

        const func_type_result_sexp = _: {
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
                param_sexp.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = param_type.wasm_type.? } };
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
            // FIXME: this leaks! (except not really cuz arena) symbols are assumed to be borrowed!
            (try impl_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "${s}", .{complete_func_type_desc.name}) } };

            for (func_decl.param_names, complete_func_type_desc.func_type.?.param_types) |param_name, param_type| {
                const param_sexp = try impl_sexp.value.list.addOne();
                param_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try param_sexp.value.list.ensureTotalCapacityPrecise(3);
                (try param_sexp.value.list.addOne()).* = wat_syms.param;
                (try param_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "$param_{s}", .{param_name}) } };
                (try param_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = param_type.wasm_type.? } };
            }

            const result_sexp = try impl_sexp.value.list.addOne();
            result_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try result_sexp.value.list.ensureTotalCapacityPrecise(2);
            result_sexp.value.list.addOneAssumeCapacity().* = wat_syms.result;

            // FIXME: horrible name
            const func_result_sexp = result_sexp.value.list.addOneAssumeCapacity();

            // NOTE: if these are unmatched, it might mean a typeof for that local is missing
            for (func_decl.local_names, complete_func_type_desc.func_type.?.local_types) |local_name, local_type| {
                const local_sexp = try impl_sexp.value.list.addOne();
                local_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try local_sexp.value.list.ensureTotalCapacityPrecise(3);
                local_sexp.value.list.addOneAssumeCapacity().* = wat_syms.local;
                local_sexp.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "$local_{s}", .{local_name}) } };
                local_sexp.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = local_type.wasm_type.? } };
            }

            const additional_locals_index = impl_sexp.value.list.items.len;

            std.debug.assert(func_decl.body_exprs.len >= 1);
            for (func_decl.body_exprs) |body_expr| {
                var prologue = std.ArrayList(Sexp).init(alloc);
                defer prologue.deinit();
                var post_analysis_locals = std.ArrayList(Sexp).init(alloc);
                defer post_analysis_locals.deinit();

                // FIXME: make next_local automatic in the expression context
                // probably possible by separating the global expr_ctx from the type context
                // which can change
                var next_local: usize = 0;
                var expr_ctx = ExprContext{
                    .locals_sexp = &post_analysis_locals,
                    .local_names = func_decl.local_names,
                    .local_types = func_decl.local_types,
                    .param_names = func_decl.param_names,
                    .param_types = func_type.param_types,
                    .prologue = &prologue,
                    .frame = .{},
                    .next_local = &next_local,
                };
                var body_fragment = try self.compileExpr(&body_expr, &expr_ctx);
                errdefer body_fragment.deinit(alloc);

                func_type_result_sexp.* = Sexp{ .value = .{ .symbol = body_fragment.resolved_type.wasm_type.? } };
                func_result_sexp.* = func_type_result_sexp.*;

                std.debug.assert(func_type.result_types.len == 1);
                if (body_fragment.resolved_type != func_type.result_types[0]) {
                    std.log.warn("body_fragment:\n{}\n", .{Sexp{ .value = .{ .module = body_fragment.values } }});
                    std.log.warn("type: '{s}' doesn't match '{s}'", .{ body_fragment.resolved_type.name, func_type.result_types[0].name });
                    // FIXME/HACK: re-enable but disabling now to allow for type promotion
                    //return error.ReturnTypeMismatch;
                }

                try impl_sexp.value.list.insertSlice(additional_locals_index, post_analysis_locals.items);
                try impl_sexp.value.list.appendSlice(prologue.items);

                // FIXME: what about the rest of the code?
                // NOTE: inserting fragments must occur after inserting the locals!
                try impl_sexp.value.list.appendSlice(try body_fragment.values.toOwnedSlice());
                body_fragment.values.clearAndFree();
            }
        }
    }

    /// A fragment of compiled code and the type of its final variable
    const Fragment = struct {
        /// values used to reference this fragment
        values: std.ArrayList(Sexp),
        /// offset in the stack frame for the value in this fragment
        frame_offset: u32 = 0,
        resolved_type: Type,

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            (Sexp{ .value = .{ .list = self.values } }).deinit(alloc);
        }
    };

    fn resolvePeerTypesWithPromotions(self: *@This(), a: *Fragment, b: *Fragment) !Type {
        if (a.resolved_type == builtin.empty_type)
            return b.resolved_type;

        if (b.resolved_type == builtin.empty_type)
            return a.resolved_type;

        // REPORT: zig can't switch on constant pointers
        const resolved_type = _: {
            if (a.resolved_type == primitive_types.bool_) {
                if (b.resolved_type == primitive_types.bool_) break :_ primitive_types.bool_;
                if (b.resolved_type == primitive_types.i32_) break :_ primitive_types.i32_;
                if (b.resolved_type == primitive_types.i64_) break :_ primitive_types.i64_;
                if (b.resolved_type == primitive_types.f32_) break :_ primitive_types.f32_;
                if (b.resolved_type == primitive_types.f64_) break :_ primitive_types.f64_;
            } else if (a.resolved_type == primitive_types.i32_) {
                if (b.resolved_type == primitive_types.bool_) break :_ primitive_types.i32_;
                if (b.resolved_type == primitive_types.i32_) break :_ primitive_types.i32_;
                if (b.resolved_type == primitive_types.i64_) break :_ primitive_types.i64_;
                if (b.resolved_type == primitive_types.f32_) break :_ primitive_types.f32_;
                if (b.resolved_type == primitive_types.f64_) break :_ primitive_types.f64_;
            } else if (a.resolved_type == primitive_types.i64_) {
                if (b.resolved_type == primitive_types.bool_) break :_ primitive_types.i64_;
                if (b.resolved_type == primitive_types.i32_) break :_ primitive_types.i64_;
                if (b.resolved_type == primitive_types.i64_) break :_ primitive_types.i64_;
                if (b.resolved_type == primitive_types.f32_) break :_ primitive_types.f32_;
                if (b.resolved_type == primitive_types.f64_) break :_ primitive_types.f64_;
            } else if (a.resolved_type == primitive_types.f32_) {
                if (b.resolved_type == primitive_types.bool_) break :_ primitive_types.f32_;
                if (b.resolved_type == primitive_types.i32_) break :_ primitive_types.f32_;
                if (b.resolved_type == primitive_types.i64_) break :_ primitive_types.f32_;
                if (b.resolved_type == primitive_types.f32_) break :_ primitive_types.f32_;
                if (b.resolved_type == primitive_types.f64_) break :_ primitive_types.f64_;
            } else if (a.resolved_type == primitive_types.f64_) {
                if (b.resolved_type == primitive_types.bool_) break :_ primitive_types.f64_;
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

                std.debug.assert(fragment.values.items.len == 1);

                if (fragment.resolved_type == primitive_types.bool_) {
                    fragment.resolved_type = primitive_types.i32_;
                    continue;
                }

                const prev = fragment.values.items[0];
                fragment.values.items[0] = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try fragment.values.items[0].value.list.ensureTotalCapacityPrecise(2);
                const converter = fragment.values.items[0].value.list.addOneAssumeCapacity();
                fragment.values.items[0].value.list.addOneAssumeCapacity().* = prev;

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

        const data_str_len = data_str.items.len;

        data_form.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{
            .ownedString = try data_str.toOwnedSlice(),
        } };

        offset_spec.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
        try offset_spec.value.list.ensureTotalCapacityPrecise(2);
        offset_spec.value.list.addOneAssumeCapacity().* = wat_syms.ops.i32_.@"const";
        offset_spec.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = @intCast(self.next_global_data_ptr) } };
        const prev_global_data_ptr = self.next_global_data_ptr;
        self.next_global_data_ptr += data_str_len;
        errdefer self.next_global_data_ptr = prev_global_data_ptr;

        return prev_global_data_ptr;
    }

    const StackFrame = struct {
        byte_size: usize = 0,
    };

    const ExprContext = struct {
        type: ?Type = null,
        local_names: []const []const u8,
        local_types: []const Type,
        param_names: []const []const u8,
        param_types: []const Type,

        frame: StackFrame,
        next_local: *usize,
        /// to append new locals to
        locals_sexp: *std.ArrayList(Sexp),
        /// to append setup code to
        prologue: *std.ArrayList(Sexp),

        /// sometimes, e.g. when creating a vstack slot, we need a local to
        /// hold the pointer to it
        /// @returns a Sexp{.value = .symbol}
        pub fn addLocal(self: *@This(), alloc: std.mem.Allocator, type_: Type) !Sexp {
            const name = try std.fmt.allocPrint(alloc, "$__lc{}", .{self.next_local.*});
            // lol?
            defer self.next_local.* += 1;
            errdefer self.next_local.* -= 1;

            // FIXME: symbols should be ownable! (doesn't matter tho cuz arena)
            const sym = Sexp{ .value = .{ .symbol = name } };

            const local_sexp = try self.locals_sexp.addOne();
            local_sexp.* = Sexp.newList(alloc);
            try local_sexp.value.list.ensureTotalCapacityPrecise(3);
            local_sexp.value.list.addOneAssumeCapacity().* = wat_syms.local;
            local_sexp.value.list.addOneAssumeCapacity().* = sym;
            local_sexp.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = type_.wasm_type.? } };

            return sym;
        }
    };

    // TODO: take a diagnostic
    fn compileExpr(
        self: *@This(),
        code_sexp: *const Sexp,
        /// not const because we may be expanding the frame to include this value
        context: *ExprContext,
    ) !Fragment {
        const alloc = self.arena.allocator();

        var result = Fragment{
            .values = std.ArrayList(Sexp).init(alloc),
            .resolved_type = builtin.empty_type,
        };

        if (context.type != null and context.type.? == primitive_types.code) {
            var bytes = std.ArrayList(u8).init(alloc);
            defer bytes.deinit();

            // FIXME: wasteful to translate to an in-memory jsonValue, just write it directly as JSON to the stream
            const json_value = try code_sexp.jsonValue(alloc);
            var jws = std.json.writeStream(bytes.writer(), .{ .escape_unicode = true });
            try json_value.jsonStringify(&jws);

            const data_offset = try self.addReadonlyData(bytes.items);

            try result.values.ensureTotalCapacityPrecise(2);
            const len = result.values.addOneAssumeCapacity();
            const ptr = result.values.addOneAssumeCapacity();

            len.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try len.value.list.ensureTotalCapacityPrecise(2);
            len.value.list.addOneAssumeCapacity().* = wat_syms.ops.i32_.@"const";
            len.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = @intCast(bytes.items.len) } };

            ptr.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try ptr.value.list.ensureTotalCapacityPrecise(2);
            ptr.value.list.addOneAssumeCapacity().* = wat_syms.ops.i32_.@"const";
            ptr.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = @intCast(data_offset + @sizeOf(usize)) } };

            return result;
        }

        switch (code_sexp.value) {
            .list => |v| {
                std.debug.assert(v.items.len >= 1);
                const func = &v.items[0];
                std.debug.assert(func.value == .symbol);

                if (func.value.symbol.ptr == syms.@"return".value.symbol.ptr or func.value.symbol.ptr == syms.begin.value.symbol.ptr) {
                    try result.values.ensureUnusedCapacity(v.items.len - 1);
                    for (v.items[1..]) |*expr| {
                        var compiled = try self.compileExpr(expr, context);
                        result.resolved_type = try self.resolvePeerTypesWithPromotions(&result, &compiled);
                        try result.values.appendSlice(compiled.values.items);
                        compiled.values.clearAndFree();
                    }
                    return result;
                }

                // call host functions
                const func_node_desc = self.env.getNode(func.value.symbol) orelse {
                    std.log.err("while in:\n{}\n", .{code_sexp});
                    std.log.err("undefined symbol1: '{}'\n", .{func});
                    return error.UndefinedSymbol;
                };

                const arg_fragments = try alloc.alloc(Fragment, v.items.len - 1);
                errdefer for (arg_fragments) |*frag| frag.deinit(alloc);
                defer alloc.free(arg_fragments);

                const if_inputs = [_]builtin.Pin{
                    builtin.Pin{
                        .name = "condition",
                        .kind = .{ .primitive = .{ .value = primitive_types.bool_ } },
                    },
                    builtin.Pin{
                        .name = "then",
                        .kind = .{ .primitive = .{ .value = builtin.empty_type } },
                    },
                    builtin.Pin{
                        .name = "else",
                        .kind = .{ .primitive = .{ .value = builtin.empty_type } },
                    },
                };

                // FIXME: gross to ignore the first exec occasionally, need to better distinguish between non/pure nodes
                const input_descs = _: {
                    if (func.value.symbol.ptr == syms.@"if".value.symbol.ptr) {
                        // FIXME: handle this better...
                        std.debug.assert(arg_fragments.len == 3);
                        break :_ &if_inputs;
                    } else if (func_node_desc.getInputs().len > 0 and func_node_desc.getInputs()[0].asPrimitivePin() == .exec) {
                        break :_ func_node_desc.getInputs()[1..];
                    } else {
                        break :_ func_node_desc.getInputs();
                    }
                };

                for (v.items[1..], arg_fragments, input_descs) |arg_src, *arg_fragment, input_desc| {
                    std.debug.assert(input_desc.asPrimitivePin() == .value);
                    var subcontext = ExprContext{
                        .type = input_desc.asPrimitivePin().value,
                        .local_names = context.local_names,
                        .local_types = context.local_types,
                        .param_names = context.param_names,
                        .param_types = context.param_types,
                        .prologue = context.prologue,
                        .locals_sexp = context.locals_sexp,
                        .frame = context.frame,
                        .next_local = context.next_local,
                    };
                    arg_fragment.* = try self.compileExpr(&arg_src, &subcontext);
                }

                if (func.value.symbol.ptr == syms.@"set!".value.symbol.ptr) {
                    std.debug.assert(arg_fragments.len == 2);

                    std.debug.assert(arg_fragments[0].values.items.len == 1);
                    std.debug.assert(arg_fragments[0].values.items[0].value == .list);
                    std.debug.assert(arg_fragments[0].values.items[0].value.list.items.len == 2);
                    std.debug.assert(arg_fragments[0].values.items[0].value.list.items[0].value == .symbol);
                    std.debug.assert(arg_fragments[0].values.items[0].value.list.items[1].value == .symbol);

                    result.resolved_type = try self.resolvePeerTypesWithPromotions(&arg_fragments[0], &arg_fragments[1]);

                    // FIXME: leak
                    const set_sym = arg_fragments[0].values.items[0].value.list.items[1];

                    std.debug.assert(arg_fragments[1].values.items.len == 1);
                    const set_val = arg_fragments[1].values.items[0];

                    try result.values.ensureTotalCapacityPrecise(1);
                    const wasm_op = result.values.addOneAssumeCapacity();
                    wasm_op.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                    try wasm_op.value.list.ensureTotalCapacityPrecise(3);
                    wasm_op.value.list.addOneAssumeCapacity().* = wat_syms.ops.@"local.set";

                    wasm_op.value.list.addOneAssumeCapacity().* = set_sym;
                    // TODO: more idiomatic move out data
                    arg_fragments[0].values.items[0] = Sexp{ .value = .void };

                    wasm_op.value.list.addOneAssumeCapacity().* = set_val;
                    // TODO: more idiomatic move out data
                    arg_fragments[1].values.items[0] = Sexp{ .value = .void };

                    return result;
                }

                if (func.value.symbol.ptr == syms.@"if".value.symbol.ptr) {
                    std.debug.assert(arg_fragments.len == 3);

                    result.resolved_type = try self.resolvePeerTypesWithPromotions(&arg_fragments[1], &arg_fragments[2]);

                    try result.values.ensureTotalCapacityPrecise(1);
                    const wasm_op = result.values.addOneAssumeCapacity();
                    wasm_op.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                    try wasm_op.value.list.ensureTotalCapacityPrecise(5);
                    wasm_op.value.list.addOneAssumeCapacity().* = syms.@"if";
                    const result_type = wasm_op.value.list.addOneAssumeCapacity();
                    const cond = wasm_op.value.list.addOneAssumeCapacity();
                    const consequence = wasm_op.value.list.addOneAssumeCapacity();
                    const alternative = wasm_op.value.list.addOneAssumeCapacity();

                    result_type.* = Sexp.newList(alloc);

                    std.debug.assert(arg_fragments[0].values.items.len == 1);
                    cond.* = arg_fragments[0].values.items[0];
                    arg_fragments[0].values.items[0] = Sexp{ .value = .void };

                    consequence.* = Sexp.newList(alloc);
                    try consequence.value.list.ensureTotalCapacityPrecise(1 + arg_fragments[1].values.items.len);
                    consequence.value.list.addOneAssumeCapacity().* = wat_syms.then;
                    for (arg_fragments[1].values.items) |*then_code| {
                        consequence.value.list.addOneAssumeCapacity().* = then_code.*;
                        then_code.* = Sexp{ .value = .void };
                    }

                    alternative.* = Sexp.newList(alloc);
                    try alternative.value.list.ensureTotalCapacityPrecise(1 + arg_fragments[2].values.items.len);
                    alternative.value.list.addOneAssumeCapacity().* = wat_syms.@"else";
                    for (arg_fragments[2].values.items) |*else_code| {
                        alternative.value.list.addOneAssumeCapacity().* = else_code.*;
                        else_code.* = Sexp{ .value = .void };
                    }

                    try result_type.value.list.ensureTotalCapacityPrecise(2);
                    result_type.value.list.addOneAssumeCapacity().* = wat_syms.result;
                    result_type.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = result.resolved_type.wasm_type.? } };

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
                        .int_only = true,
                    },
                    .{
                        .sym = syms.@"and",
                        .wasm_name = "and",
                        .int_only = true,
                    },
                    .{
                        .sym = syms.@"or",
                        .wasm_name = "or",
                        .int_only = true,
                    },
                }) |builtin_op| {
                    if (func.value.symbol.ptr == builtin_op.sym.value.symbol.ptr) {
                        try result.values.ensureTotalCapacityPrecise(1);
                        const wasm_op = result.values.addOneAssumeCapacity();
                        wasm_op.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                        try wasm_op.value.list.ensureTotalCapacityPrecise(3);
                        const op_name = wasm_op.value.list.addOneAssumeCapacity();

                        std.debug.assert(arg_fragments.len == 2);
                        for (arg_fragments) |*arg_fragment| {
                            result.resolved_type = try self.resolvePeerTypesWithPromotions(&result, arg_fragment);
                            std.debug.assert(arg_fragment.values.items.len == 1);
                            // resolve peer types could have mutated it
                            (try wasm_op.value.list.addOne()).* = arg_fragment.values.items[0];
                            // TODO: more idiomatic move out data
                            arg_fragment.values.items[0] = Sexp{ .value = .void };
                        }

                        var handled = false;

                        inline for (&.{ "i32_", "i64_", "f32_", "f64_" }) |type_name| {
                            const primitive_type: Type = @field(primitive_types, type_name);
                            const float_type_but_int_op = @hasField(@TypeOf(builtin_op), "int_only") and type_name[0] == 'f';
                            if (!float_type_but_int_op and result.resolved_type == primitive_type) {
                                const wasm_type_ops = @field(wat_syms.ops, type_name);
                                op_name.* = @field(wasm_type_ops, builtin_op.wasm_name);
                                handled = true;
                            }
                        }

                        // REPORT ME: try to prefer an else on the above for loop, currently couldn't get it to compile right
                        if (!handled) {
                            std.log.err("unimplemented type resolution: '{s}' for code:\n{s}\n", .{ result.resolved_type.name, code_sexp });
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
                        try result.values.ensureTotalCapacityPrecise(1);
                        const wasm_call = result.values.addOneAssumeCapacity();
                        wasm_call.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };

                        const total_args = _: {
                            var total_args_res: usize = 2; // start with 2 for (call $FUNC_NAME ...)
                            for (arg_fragments) |arg_frag| total_args_res += arg_frag.values.items.len;
                            break :_ total_args_res;
                        };

                        try wasm_call.value.list.ensureTotalCapacityPrecise(total_args);
                        // FIXME: use types to determine
                        wasm_call.value.list.addOneAssumeCapacity().* = wat_syms.call;
                        wasm_call.value.list.addOneAssumeCapacity().* = intrinsic.wasm_sym;

                        for (arg_fragments) |arg_fragment| {
                            for (arg_fragment.values.items) |*subarg| {
                                wasm_call.value.list.addOneAssumeCapacity().* = subarg.*;
                                subarg.* = Sexp{ .value = .void };
                            }
                        }

                        return result;
                    }
                }

                // FIXME: handle quote

                // call host functions
                {
                    const outputs = func_node_desc.getOutputs();
                    result.resolved_type = if (outputs.len >= 1 and outputs[0].kind == .primitive and outputs[0].kind.primitive == .value)
                        outputs[0].kind.primitive.value
                        // FIXME: bad type resolution for void returning functions
                    else
                        primitive_types.i32_;

                    try result.values.ensureTotalCapacityPrecise(1);
                    const wasm_call = result.values.addOneAssumeCapacity();
                    wasm_call.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                    try wasm_call.value.list.ensureTotalCapacityPrecise(2 + arg_fragments.len);
                    // FIXME: use types to determine
                    wasm_call.value.list.addOneAssumeCapacity().* = wat_syms.call;
                    // FIXME: leak
                    wasm_call.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "${s}", .{func.value.symbol}) } };

                    for (arg_fragments) |arg_fragment| {
                        for (arg_fragment.values.items) |*fragment_part| {
                            (try wasm_call.value.list.addOne()).* = fragment_part.*;
                            // move out
                            fragment_part.* = Sexp{ .value = .void };
                        }
                    }

                    return result;
                }

                // otherwise we have a non builtin
                std.log.err("unhandled call: {}", .{code_sexp});
                return error.UnhandledCall;
            },

            .int => |v| {
                result.resolved_type = builtin.primitive_types.i32_;
                try result.values.ensureTotalCapacityPrecise(1);
                const wasm_const = result.values.addOneAssumeCapacity();
                wasm_const.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try wasm_const.value.list.ensureTotalCapacityPrecise(2);

                // FIXME: have a type context
                wasm_const.value.list.addOneAssumeCapacity().* = wat_syms.ops.i32_.@"const";
                wasm_const.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = v } };

                return result;
            },

            .float => |v| {
                result.resolved_type = builtin.primitive_types.f64_;
                try result.values.ensureTotalCapacityPrecise(1);
                const wasm_const = result.values.addOneAssumeCapacity();
                wasm_const.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try wasm_const.value.list.ensureTotalCapacityPrecise(2);
                wasm_const.value.list.addOneAssumeCapacity().* = wat_syms.ops.f64_.@"const";
                wasm_const.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .float = v } };

                return result;
            },

            .symbol => |v| {
                if (v.ptr == syms.true.value.symbol.ptr) {
                    result.resolved_type = primitive_types.bool_;
                    try result.values.ensureTotalCapacityPrecise(1);
                    result.values.addOneAssumeCapacity().* = Sexp.newList(alloc);
                    result.values.items[0] = Sexp.newList(alloc);
                    try result.values.items[0].value.list.ensureTotalCapacityPrecise(2);
                    result.values.items[0].value.list.addOneAssumeCapacity().* = wat_syms.ops.i32_.@"const";
                    // FIXME: these are backwards for some reason?
                    result.values.items[0].value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = 0 } };
                    return result;
                }

                if (v.ptr == syms.false.value.symbol.ptr) {
                    result.resolved_type = primitive_types.bool_;
                    try result.values.ensureTotalCapacityPrecise(1);
                    result.values.addOneAssumeCapacity().* = Sexp.newList(alloc);
                    try result.values.items[0].value.list.ensureTotalCapacityPrecise(2);
                    result.values.items[0].value.list.addOneAssumeCapacity().* = wat_syms.ops.i32_.@"const";
                    // FIXME: these are backwards for some reason?
                    result.values.items[0].value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = 1 } };
                    return result;
                }

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

                result.resolved_type = info.resolved_type;
                try result.values.ensureTotalCapacityPrecise(1);
                const wasm_local_get = result.values.addOneAssumeCapacity();
                wasm_local_get.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try wasm_local_get.value.list.ensureTotalCapacityPrecise(2);
                wasm_local_get.value.list.addOneAssumeCapacity().* = wat_syms.ops.@"local.get";
                // FIXME: leak
                wasm_local_get.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{
                    .symbol = info.ref,
                } };

                return result;
            },

            .borrowedString, .ownedString => |v| {
                const data_offset = try self.addReadonlyData(v);

                result.frame_offset += @sizeOf(intrinsics.GrapplString);
                result.resolved_type = builtin.primitive_types.string;

                const local_ptr_sym = try context.addLocal(alloc, primitive_types.string);

                // FIXME: parse this and insert substitutions at comptime!
                const mut_code_src = try std.fmt.allocPrint(alloc,
                    \\;; store length
                    \\(i32.store (global.get $__grappl_vstkp)
                    \\           (i32.const {0}))
                    \\
                    \\;; store data
                    \\(i32.store (i32.add (global.get $__grappl_vstkp)
                    \\                    (i32.const {1}))
                    \\           (i32.const {2}))
                    \\
                    \\;; store the stack pointer (cuz it points to the string)
                    \\(local.set {3} (global.get $__grappl_vstkp))
                    \\
                    \\;; now increment the stack pointer so no one overwrites this
                    \\(global.set $__grappl_vstkp
                    \\            (i32.add (global.get $__grappl_vstkp)
                    \\                     (i32.const {4})))
                , .{
                    v.len,
                    @sizeOf(std.meta.fields(intrinsics.GrapplString)[0].type),
                    data_offset + @sizeOf(usize),
                    local_ptr_sym,
                    @sizeOf(intrinsics.GrapplString),
                });
                var diag = SexpParser.Diagnostic{ .source = mut_code_src };
                var mut_code = SexpParser.parse(alloc, mut_code_src, &diag) catch {
                    std.log.err("diag={}", .{diag});
                    @panic("failed to parse temp non-comptime mut_code_src");
                };
                errdefer mut_code.deinit(alloc);

                context.frame.byte_size += @sizeOf(intrinsics.GrapplString);

                var vals_code = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                errdefer vals_code.deinit(alloc);
                try vals_code.value.list.ensureTotalCapacityPrecise(2);
                vals_code.value.list.addOneAssumeCapacity().* = wat_syms.ops.@"local.get";
                vals_code.value.list.addOneAssumeCapacity().* = local_ptr_sym;

                (try result.values.addOne()).* = vals_code;
                try context.prologue.appendSlice(try mut_code.toOwnedSlice());

                return result;
            },

            .bool => |v| {
                const int_val: i64 = if (v) 1 else 0;

                try result.values.ensureTotalCapacityPrecise(1);
                const val = result.values.addOneAssumeCapacity();

                val.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try val.value.list.ensureTotalCapacityPrecise(2);
                val.value.list.addOneAssumeCapacity().* = wat_syms.ops.i32_.@"const";
                val.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = int_val } };

                result.resolved_type = builtin.primitive_types.bool_;
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

        self.wat = Sexp{ .value = .{ .module = std.ArrayList(Sexp).init(self.arena.allocator()) } };
        try self.wat.value.module.ensureTotalCapacityPrecise(1);
        const module_body = self.wat.value.module.addOneAssumeCapacity();
        module_body.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.arena.allocator()) } };
        self.module_body = &module_body.value.list;
        try self.module_body.ensureTotalCapacity(5);
        self.module_body.addOneAssumeCapacity().* = wat_syms.module;

        const imports_src =
            //\\(func $callUserFunc_JSON_R_JSON (import "env" "callUserFunc_JSON_R_JSON") (param i32) (param i32) (param i32) (result i32) (result i32))
            \\(import "env" "callUserFunc_code_R" (func $callUserFunc_code_R (param i32) (param i32) (param i32)))
            \\(import "env" "callUserFunc_code_R_string" (func $callUserFunc_code_R_string (param i32) (param i32) (param i32) (result i32)))
            \\(import "env" "callUserFunc_string_R" (func $callUserFunc_string_R (param i32) (param i32) (param i32)))
            \\(import "env" "callUserFunc_R" (func $callUserFunc_R (param i32)))
            \\(import "env" "callUserFunc_i32_R" (func $callUserFunc_i32_R (param i32) (param i32)))
            \\(import "env" "callUserFunc_i32_R_i32" (func $callUserFunc_i32_R_i32 (param i32) (param i32) (result i32)))
            \\(import "env" "callUserFunc_i32_i32_R_i32" (func $callUserFunc_i32_i32_R_i32 (param i32) (param i32) (param i32) (result i32)))
            \\(import "env" "callUserFunc_bool_R" (func $callUserFunc_bool_R (param i32) (param i32)))
        ;

        // TODO: parse them at comptime and get the count that way
        const imports_count = comptime std.mem.count(u8, imports_src, "\n") + 1;

        // imports
        {
            const host_callbacks_prologue = try SexpParser.parse(alloc, imports_src, null);
            try self.module_body.appendSlice(host_callbacks_prologue.value.module.items);
        }

        const stack_src =
            // NOTE: safari doesn't support multimemory so the value stack is
            // at a specific offset in the main memory
            //\\(memory $__grappl_vstk 1)
            // FIXME: really need to figure out how to customize the intrinsics output
            // compiled by zig... or accept writing it manually?
            // FIXME: if there is a lot of data, it will corrupt the stack,
            // need to place the stack behind the data and possibly implement a routine
            // for growing the stack...
            \\(global $__grappl_vstkp (mut i32) (i32.const 4096))
        ;

        // prologue
        {
            const stack_code = try SexpParser.parse(alloc, stack_src, null);
            try self.module_body.appendSlice(stack_code.value.module.items);
        }

        // TODO: parse them at comptime and get the count that way
        const stack_code_count = comptime std.mem.count(u8, stack_src, "\n") + 1;

        // FIXME: memory is already created and exported by the intrinsics
        // {
        //     const memory = self.module_body.addOneAssumeCapacity();
        //     memory.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.arena.allocator()) } };
        //     try memory.value.list.ensureTotalCapacityPrecise(3);
        //     memory.value.list.addOneAssumeCapacity().* = wat_syms.memory;
        //     memory.value.list.addOneAssumeCapacity().* = wat_syms.@"$0";
        //     memory.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = 1 } }; // require at least 1 page of memory
        // }

        // {
        //     // TODO: export helper
        //     const memory_export = self.module_body.addOneAssumeCapacity();
        //     memory_export.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.arena.allocator()) } };
        //     try memory_export.value.list.ensureTotalCapacityPrecise(3);
        //     memory_export.value.list.addOneAssumeCapacity().* = wat_syms.@"export";
        //     memory_export.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .borrowedString = "memory" } };
        //     const memory_export_val = memory_export.value.list.addOneAssumeCapacity();
        //     memory_export_val.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.arena.allocator()) } };
        //     try memory_export_val.value.list.ensureTotalCapacityPrecise(2);
        //     memory_export_val.value.list.addOneAssumeCapacity().* = wat_syms.memory;
        //     memory_export_val.value.list.addOneAssumeCapacity().* = wat_syms.@"$0";
        // }

        // thunks for user provided functions
        {
            // TODO: for each user provided function, build a thunk and append it
            var maybe_user_func = self.user_context.funcs.first;
            while (maybe_user_func) |user_func| : (maybe_user_func = user_func.next) {
                // FIXME: leak kinda but arena
                const name = try std.fmt.allocPrint(alloc, "${s}", .{user_func.data.node.name});

                // FIXME: skip the first exec input
                std.debug.assert(user_func.data.node.inputs[0].kind.primitive == .exec);
                const params = user_func.data.node.inputs[1..];

                // FIXME: skip the first exec output
                std.debug.assert(user_func.data.node.outputs[0].kind.primitive == .exec);
                const results = user_func.data.node.outputs[1..];

                var thunk_buf: [1024]u8 = undefined;
                var thunk_buf_writer = std.io.fixedBufferStream(&thunk_buf);
                _ = try thunk_buf_writer.write("$callUserFunc_");
                for (params) |param| {
                    _ = try thunk_buf_writer.write(param.kind.primitive.value.name);
                    _ = try thunk_buf_writer.write("_");
                }
                _ = try thunk_buf_writer.write("R");
                for (results) |result| {
                    _ = try thunk_buf_writer.write("_");
                    _ = try thunk_buf_writer.write(result.kind.primitive.value.name);
                }

                const thunk_name = try alloc.dupe(u8, thunk_buf_writer.getWritten());

                var user_func_sexp = Sexp.newList(alloc);
                const thunk_len = (1 // func keyword
                + 1 // function name
                + 2 * params.len // twice in case they are all strings
                + 1 * results.len + 1 // call binding
                );
                try user_func_sexp.value.list.ensureTotalCapacityPrecise(thunk_len);
                user_func_sexp.value.list.addOneAssumeCapacity().* = wat_syms.func;
                user_func_sexp.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = name } };

                {
                    var i: usize = 0;
                    for (params) |param| {
                        const param_type = param.asPrimitivePin().value;

                        // FIXME/HACK: string/code should be a pointer, so don't pass it as two params
                        const param_actual_count: usize =
                            if (param_type == primitive_types.string or param_type == primitive_types.code)
                            2
                        else
                            1;

                        for (0..param_actual_count) |_| {
                            var wasm_param = user_func_sexp.value.list.addOneAssumeCapacity();
                            wasm_param.* = Sexp.newList(alloc);
                            try wasm_param.value.list.ensureTotalCapacityPrecise(3);

                            wasm_param.value.list.addOneAssumeCapacity().* = wat_syms.param;
                            wasm_param.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "$param_{}", .{i}) } };
                            // FIXME/HACK: this doesn't work for many types!
                            wasm_param.value.list.addOneAssumeCapacity().* = if (param.asPrimitivePin().value.wasm_type) |wasm_type| Sexp{ .value = .{ .symbol = wasm_type } } else wat_syms.ops.i32_.self;

                            i += 1;
                        }
                    }
                }

                {
                    var i: usize = 0;
                    for (results) |result| {
                        //const result_type = result.asPrimitivePin().value;

                        var wasm_param = user_func_sexp.value.list.addOneAssumeCapacity();
                        wasm_param.* = Sexp.newList(alloc);
                        try wasm_param.value.list.ensureTotalCapacityPrecise(2);

                        wasm_param.value.list.addOneAssumeCapacity().* = wat_syms.result;
                        // FIXME/HACK: this doesn't work for many types!
                        wasm_param.value.list.addOneAssumeCapacity().* = if (result.asPrimitivePin().value.wasm_type) |wasm_type| Sexp{ .value = .{ .symbol = wasm_type } } else wat_syms.ops.i32_.self;

                        i += 1;
                    }
                }

                const call_body = user_func_sexp.value.list.addOneAssumeCapacity();
                call_body.* = Sexp.newList(alloc);
                try call_body.value.list.ensureTotalCapacityPrecise(1 // call keyword
                + 1 // thunk name
                + 1 // func id
                + 2 * params.len // twice in case they are strings
                );

                call_body.value.list.addOneAssumeCapacity().* = wat_syms.call;
                call_body.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = thunk_name } };
                const func_id = call_body.value.list.addOneAssumeCapacity();
                func_id.* = Sexp.newList(alloc);
                try func_id.value.list.ensureTotalCapacityPrecise(2);
                func_id.value.list.addOneAssumeCapacity().* = wat_syms.ops.i32_.@"const";
                func_id.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .int = @intCast(user_func.data.id) } };

                {
                    var i: usize = 0;
                    for (params) |param| {
                        const param_type = param.asPrimitivePin().value;

                        // FIXME/HACK: string/code should be a pointer, so don't pass it as two params
                        const param_actual_count: usize =
                            if (param_type == primitive_types.string or param_type == primitive_types.code)
                            2
                        else
                            1;

                        for (0..param_actual_count) |_| {
                            const wasm_local = call_body.value.list.addOneAssumeCapacity();
                            wasm_local.* = Sexp.newList(alloc);
                            try wasm_local.value.list.ensureTotalCapacityPrecise(2);
                            // FIXME: does this work for non-primitives?
                            wasm_local.value.list.addOneAssumeCapacity().* = wat_syms.ops.@"local.get";
                            wasm_local.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "$param_{}", .{i}) } };

                            i += 1;
                        }
                    }
                }

                (try self.module_body.addOne()).* = user_func_sexp;
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
                        std.log.err("{}", .{self.diag});
                        return error.badTopLevelForm;
                    }
                },
                else => {
                    self.diag.err = Diagnostic.Error{ .BadTopLevelForm = &decl };
                    std.log.err("{}", .{self.diag});
                    return error.badTopLevelForm;
                },
            }
        }

        var bytes = std.ArrayList(u8).init(self.arena.allocator());
        defer bytes.deinit();
        const buffer_writer = bytes.writer();

        // FIXME: come up with a way to just say assert(self.wat.like("(module"))
        std.debug.assert(self.wat.value == .module);
        std.debug.assert(self.wat.value.module.items.len == 1);
        std.debug.assert(self.wat.value.module.items[0].value == .list);
        std.debug.assert(self.wat.value.module.items[0].value.list.items.len >= 1);
        std.debug.assert(self.wat.value.module.items[0].value.list.items[0].value == .symbol);
        std.debug.assert(self.wat.value.module.items[0].value.list.items[0].value.symbol.ptr == wat_syms.module.value.symbol.ptr);
        // FIXME: performantly parse the wat at compile time or use wasm merge
        // I don't trust my parser yet
        const module_contents = self.wat.value.module.items[0].value.list.items[1..];
        std.debug.assert(module_contents.len >= imports_count + stack_code_count);
        const imports = module_contents[0..imports_count];
        const stack_code = module_contents[imports_count .. imports_count + stack_code_count];
        const module_defs = module_contents[imports_count + stack_code_count ..];

        try bytes.appendSlice("(module\n");

        // imports must be first in wat!
        for (imports) |import| {
            _ = try import.write(buffer_writer);
            try bytes.appendSlice("\n");
        }

        for (stack_code) |code| {
            _ = try code.write(buffer_writer);
            try bytes.appendSlice("\n");
        }

        // FIXME: HACK: merge these properly...
        try bytes.appendSlice(";;; BEGIN INTRINSICS\n");
        try bytes.appendSlice(intrinsics_code);
        try bytes.appendSlice("\n;;; END INTRINSICS\n");

        for (module_defs) |def| {
            _ = try def.write(buffer_writer);
            try bytes.appendSlice("\n");
        }

        try bytes.appendSlice(")");

        // FIXME: make the arena in this function not the caller
        // NOTE: use arena parent so that when the arena deinit's, this remains,
        // and the caller can own the memory
        return try self.arena.child_allocator.dupe(u8, bytes.items);
    }
};

pub fn compile(
    a: std.mem.Allocator,
    sexp: *const Sexp,
    env: *const Env,
    user_funcs: ?*std.SinglyLinkedList(UserFunc),
    _in_diagnostic: ?*Diagnostic,
) ![]const u8 {
    if (build_opts.disable_compiler) unreachable;
    var ignored_diagnostic: Diagnostic = undefined; // FIXME: why don't we init?
    const diag = if (_in_diagnostic) |d| d else &ignored_diagnostic;
    diag.module = sexp;

    var mut_env = env.spawn();

    var unit = try Compilation.init(a, &mut_env, user_funcs, diag);
    defer unit.deinit();

    return unit.compileModule(sexp);
}

const t = std.testing;
const SexpParser = @import("./sexp_parser.zig").Parser;

test "compile big" {
    // FIXME: support expression functions
    //     \\(define (++ x) (+ x 1))

    var user_funcs = std.SinglyLinkedList(UserFunc){};

    const user_func_1 = try t.allocator.create(std.SinglyLinkedList(UserFunc).Node);
    user_func_1.* = std.SinglyLinkedList(UserFunc).Node{
        .data = .{ .id = 0, .node = .{
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
        } },
    };
    defer t.allocator.destroy(user_func_1);
    defer t.allocator.free(user_func_1.data.node.inputs);
    defer t.allocator.free(user_func_1.data.node.outputs);
    user_funcs.prepend(user_func_1);

    const user_func_2 = try t.allocator.create(std.SinglyLinkedList(UserFunc).Node);
    user_func_2.* = std.SinglyLinkedList(UserFunc).Node{
        .data = .{
            .id = 1,
            .node = .{
                .name = "sql",
                .inputs = try t.allocator.dupe(builtin.Pin, &.{
                    builtin.Pin{ .name = "exec", .kind = .{ .primitive = .exec } },
                    builtin.Pin{
                        .name = "code",
                        .kind = .{ .primitive = .{ .value = primitive_types.code } },
                    },
                }),
                .outputs = try t.allocator.dupe(builtin.Pin, &.{
                    builtin.Pin{ .name = "", .kind = .{ .primitive = .exec } },
                }),
            },
        },
    };
    defer t.allocator.destroy(user_func_2);
    defer t.allocator.free(user_func_2.data.node.inputs);
    defer t.allocator.free(user_func_2.data.node.outputs);
    user_funcs.prepend(user_func_2);

    var env = try Env.initDefault(t.allocator);
    defer env.deinit(t.allocator);

    {
        var maybe_cursor = user_funcs.first;
        while (maybe_cursor) |cursor| : (maybe_cursor = cursor.next) {
            _ = try env.addNode(t.allocator, builtin.basicMutableNode(&cursor.data.node));
        }
    }

    var parsed = try SexpParser.parse(t.allocator,
        \\;;; comment
        \\(typeof g i64)
        \\(define g 10)
        \\
        \\;;; comment
        \\(typeof (++ i32) i32)
        \\(define (++ x)
        \\  (begin
        \\    (typeof a i32)
        \\    (define a 2) ;; FIXME: make i64 to test type promotion
        \\    (sql (- f (* 2 3)))
        \\    (sql 4)
        \\    (set! a 1)
        \\    (Confetti 100)
        \\    (return (max x a))))
        \\
        \\;;; comment
        \\(typeof (deep f32 f32) f32)
        \\(define (deep a b)
        \\  (begin
        \\    (return (+ (/ a 10) (* a b)))))
        \\
        \\;;; comment ;; TODO: reintroduce use of a parameter
        \\(typeof (strings-stuff) bool)
        \\(define (strings-stuff)
        \\  (begin
        \\    (return (string-equal "hello" "world"))))
        \\
        \\;;; comment ;; TODO: reintroduce use of a parameter
        \\(typeof (ifs bool) i32)
        \\(define (ifs a)
        \\  (begin
        \\    (if a
        \\        (begin (Confetti 100)
        \\               (+ 2 3))
        \\        (begin (Confetti 200)
        \\               5))))
    , null);
    //std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit(t.allocator);

    const expected = try std.fmt.allocPrint(t.allocator,
        \\(module
        \\(import "env"
        \\        "callUserFunc_code_R"
        \\        (func $callUserFunc_code_R
        \\              (param i32)
        \\              (param i32)
        \\              (param i32)))
        \\(import "env"
        \\        "callUserFunc_code_R_string"
        \\        (func $callUserFunc_code_R_string
        \\              (param i32)
        \\              (param i32)
        \\              (param i32)
        \\              (result i32)))
        \\(import "env"
        \\        "callUserFunc_string_R"
        \\        (func $callUserFunc_string_R
        \\              (param i32)
        \\              (param i32)
        \\              (param i32)))
        \\(import "env"
        \\        "callUserFunc_R"
        \\        (func $callUserFunc_R
        \\              (param i32)))
        \\(import "env"
        \\        "callUserFunc_i32_R"
        \\        (func $callUserFunc_i32_R
        \\              (param i32)
        \\              (param i32)))
        \\(import "env"
        \\        "callUserFunc_i32_R_i32"
        \\        (func $callUserFunc_i32_R_i32
        \\              (param i32)
        \\              (param i32)
        \\              (result i32)))
        \\(import "env"
        \\        "callUserFunc_i32_i32_R_i32"
        \\        (func $callUserFunc_i32_i32_R_i32
        \\              (param i32)
        \\              (param i32)
        \\              (param i32)
        \\              (result i32)))
        \\(import "env"
        \\        "callUserFunc_bool_R"
        \\        (func $callUserFunc_bool_R
        \\              (param i32)
        \\              (param i32)))
        \\(global $__grappl_vstkp
        \\        (mut i32)
        \\        (i32.const 4096))
        \\;;; BEGIN INTRINSICS
        \\{s}
        \\;;; END INTRINSICS
        \\(func $sql
        \\      (param $param_0
        \\             i32)
        \\      (param $param_1
        \\             i32)
        \\      (call $callUserFunc_code_R
        \\            (i32.const 1)
        \\            (local.get $param_0)
        \\            (local.get $param_1)))
        \\(func $Confetti
        \\      (param $param_0
        \\             i32)
        \\      (call $callUserFunc_i32_R
        \\            (i32.const 0)
        \\            (local.get $param_0)))
        \\(export "++"
        \\        (func $++))
        \\(type $typeof_++
        \\      (func (param i32)
        \\            (result i32)))
        \\(func $++
        \\      (param $param_x
        \\             i32)
        \\      (result i32)
        \\      (local $local_a
        \\             i32)
        \\      (call $sql
        \\            (i32.const 52)
        \\            (i32.const 8))
        \\      (call $sql
        \\            (i32.const 1)
        \\            (i32.const 106))
        \\      (local.set $local_a
        \\                 (i32.const 1))
        \\      (call $Confetti
        \\            (i32.const 100))
        \\      (call $__grappl_max
        \\            (local.get $param_x)
        \\            (local.get $local_a)))
        \\(data (i32.const 0)
        \\      "4\00\00\00\00\00\00\00[{{\22symbol\22:\22-\22}},{{\22symbol\22:\22f\22}},[{{\22symbol\22:\22*\22}},2,3]]")
        \\(data (i32.const 98)
        \\      "\01\00\00\00\00\00\00\004")
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
        \\(export "strings-stuff"
        \\        (func $strings-stuff))
        \\(type $typeof_strings-stuff
        \\      (func (result i32)))
        \\(func $strings-stuff
        \\      (result i32)
        \\      (local $__lc0
        \\             i32)
        \\      (local $__lc1
        \\             i32)
        \\      (i32.store (global.get $__grappl_vstkp)
        \\                 (i32.const 5))
        \\      (i32.store (i32.add (global.get $__grappl_vstkp)
        \\                          (i32.const 8))
        \\                 (i32.const 131))
        \\      (local.set $__lc0
        \\                 (global.get $__grappl_vstkp))
        \\      (global.set $__grappl_vstkp
        \\                  (i32.add (global.get $__grappl_vstkp)
        \\                           (i32.const 16)))
        \\      (i32.store (global.get $__grappl_vstkp)
        \\                 (i32.const 5))
        \\      (i32.store (i32.add (global.get $__grappl_vstkp)
        \\                          (i32.const 8))
        \\                 (i32.const 160))
        \\      (local.set $__lc1
        \\                 (global.get $__grappl_vstkp))
        \\      (global.set $__grappl_vstkp
        \\                  (i32.add (global.get $__grappl_vstkp)
        \\                           (i32.const 16)))
        \\      (call $__grappl_string_equal
        \\            (local.get $__lc0)
        \\            (local.get $__lc1)))
        \\(data (i32.const 123)
        \\      "\05\00\00\00\00\00\00\00hello")
        \\(data (i32.const 152)
        \\      "\05\00\00\00\00\00\00\00world")
        \\(export "ifs"
        \\        (func $ifs))
        \\(type $typeof_ifs
        \\      (func (param i32)
        \\            (result i32)))
        \\(func $ifs
        \\      (param $param_a
        \\             i32)
        \\      (result i32)
        \\      (if (result i32)
        \\          (local.get $param_a)
        \\          (then (call $Confetti
        \\                      (i32.const 100))
        \\                (i32.add (i32.const 2)
        \\                         (i32.const 3)))
        \\          (else (call $Confetti
        \\                      (i32.const 200))
        \\                (i32.const 5))))
        \\)
        // TODO: clearly instead of embedding the pointer we should have a global variable
        // so the host can set that
    , .{intrinsics_code});
    defer t.allocator.free(expected);

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &env, &user_funcs, &diagnostic)) |wat| {
        // FIXME: convenience
        var tmp_dir = try std.fs.openDirAbsolute("/tmp", .{});
        defer tmp_dir.close();

        var dbg_file = try tmp_dir.createFile("compiler-test.wat", .{});
        defer dbg_file.close();

        try dbg_file.writeAll(wat);

        try t.expectEqualStrings(expected, wat);

        t.allocator.free(wat);
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}

test "recurse" {
    // FIXME: support expression functions
    //     \\(define (++ x) (+ x 1))

    var env = try Env.initDefault(t.allocator);
    defer env.deinit(t.allocator);

    // FIXME: easier in the IDE to just pass the augmented env, but probably
    // better if the compiler can take a default env
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
    //std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit(t.allocator);

    const expected = try std.fmt.allocPrint(t.allocator,
        \\(module
        \\(import "env"
        \\        "callUserFunc_code_R"
        \\        (func $callUserFunc_code_R
        \\              (param i32)
        \\              (param i32)
        \\              (param i32)))
        \\(import "env"
        \\        "callUserFunc_code_R_string"
        \\        (func $callUserFunc_code_R_string
        \\              (param i32)
        \\              (param i32)
        \\              (param i32)
        \\              (result i32)))
        \\(import "env"
        \\        "callUserFunc_string_R"
        \\        (func $callUserFunc_string_R
        \\              (param i32)
        \\              (param i32)
        \\              (param i32)))
        \\(import "env"
        \\        "callUserFunc_R"
        \\        (func $callUserFunc_R
        \\              (param i32)))
        \\(import "env"
        \\        "callUserFunc_i32_R"
        \\        (func $callUserFunc_i32_R
        \\              (param i32)
        \\              (param i32)))
        \\(import "env"
        \\        "callUserFunc_i32_R_i32"
        \\        (func $callUserFunc_i32_R_i32
        \\              (param i32)
        \\              (param i32)
        \\              (result i32)))
        \\(import "env"
        \\        "callUserFunc_i32_i32_R_i32"
        \\        (func $callUserFunc_i32_i32_R_i32
        \\              (param i32)
        \\              (param i32)
        \\              (param i32)
        \\              (result i32)))
        \\(import "env"
        \\        "callUserFunc_bool_R"
        \\        (func $callUserFunc_bool_R
        \\              (param i32)
        \\              (param i32)))
        \\(global $__grappl_vstkp
        \\        (mut i32)
        \\        (i32.const 4096))
        \\;;; BEGIN INTRINSICS
        \\{s}
        \\;;; END INTRINSICS
        \\(export "factorial"
        \\        (func $factorial))
        \\(type $typeof_factorial
        \\      (func (param i32)
        \\            (result i32)))
        \\(func $factorial
        \\      (param $param_n
        \\             i32)
        \\      (result i32)
        \\      (if (result i32)
        \\          (i32.le_s (local.get $param_n)
        \\                    (i32.const 1))
        \\          (then (i32.const 1))
        \\          (else (i32.mul (local.get $param_n)
        \\                         (call $factorial
        \\                               (i32.sub (local.get $param_n)
        \\                                        (i32.const 1)))))))
        \\)
        // TODO: clearly instead of embedding the pointer we should have a global variable
        // so the host can set that
    , .{intrinsics_code});
    defer t.allocator.free(expected);

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &env, null, &diagnostic)) |wat| {
        // FIXME: convenience
        var tmp_dir = try std.fs.openDirAbsolute("/tmp", .{});
        defer tmp_dir.close();

        var dbg_file = try tmp_dir.createFile("compiler-test.wat", .{});
        defer dbg_file.close();

        try dbg_file.writeAll(wat);

        try t.expectEqualStrings(expected, wat);

        t.allocator.free(wat);
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}
