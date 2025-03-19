//!
//! NOTE:
//! - functions starting with ";" will cause a multiline comment, which is an example
//!   of small problems with this code not conforming to WAT precisely
//!
//! REWRITE PLAN:
//! - every node value is a stack slot
//! - every CFG or path (until labeled nodes) is a block (wasm loop)
//! - if the node is pure, it is calculated once at usage time
//! - otherwise the code just jumps to these blocks
//!

const builtin = @import("builtin");
const build_opts = @import("build_opts");
const std = @import("std");
const json = std.json;
const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;
const primitive_type_syms = @import("./sexp.zig").primitive_type_syms;
const graphl_builtin = @import("./nodes/builtin.zig");
const primitive_types = @import("./nodes/builtin.zig").primitive_types;
const Env = @import("./nodes//builtin.zig").Env;
const TypeInfo = @import("./nodes/builtin.zig").TypeInfo;
const Type = @import("./nodes/builtin.zig").Type;
const builtin_nodes = @import("./nodes/builtin.zig").builtin_nodes;
const Pin = @import("./nodes/builtin.zig").Pin;
const pool = &@import("./InternPool.zig").pool;

// FIXME: use intrinsics as the base and merge/link in our functions
const intrinsics = @import("./intrinsics.zig");
const intrinsics_raw = @embedFile("graphl_intrinsics");
const intrinsics_code = intrinsics_raw["(module $graphl_intrinsics.wasm\n".len .. intrinsics_raw.len - 2];

pub const Diagnostic = struct {
    err: Error = .None,

    // set upon start of compilation
    /// the sexp parsed from the source contextually related to the stored error
    root_sexp: *const Sexp = undefined,

    const Error = union(enum(u16)) {
        // TODO: lowercase
        None = 0,
        BadTopLevelForm: *const Sexp = 1,
        UndefinedSymbol: [:0]const u8 = 2,
    };

    const Code = error{
        // TODO: capitalize
        badTopLevelForm,
        undefinedSymbol,
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
        // TODO: add a source-contextualize function using source location
        _ = fmt_str;
        _ = fmt_opts;
        switch (self.err) {
            .None => try writer.print("Not an error", .{}),
            .BadTopLevelForm => |decl| {
                try writer.print("bad top level form:\n{}\n", .{decl});
                try writer.print("in:\n{}\n", .{self.root_sexp});
            },
            // TODO: add a contextualize function?
            .UndefinedSymbol => |sym| {
                try writer.print("undefined symbol '{s}'\n", .{sym});
            },
        }
    }
};

const DeferredFuncDeclInfo = struct {
    param_names: []const [:0]const u8,
    local_names: []const [:0]const u8,
    local_types: []const Type,
    local_defaults: []const Sexp,
    result_names: []const [:0]const u8,
    body_exprs: []const Sexp,
};

const DeferredFuncTypeInfo = struct {
    param_types: []const Type,
    result_types: []const Type,
};

var empty_user_funcs = std.SinglyLinkedList(UserFunc){};

pub const UserFunc = struct {
    id: usize,
    node: graphl_builtin.BasicMutNodeDesc,
};

const binaryop_builtins = .{
    .{
        .sym = syms.@"+",
        .wasm_name = "add",
        .signless = true,
    },
    .{
        .sym = syms.@"-",
        .wasm_name = "sub",
        .signless = true,
    },
    .{
        .sym = syms.@"*",
        .wasm_name = "mul",
        .signless = true,
    },
    .{
        .sym = syms.@"/",
        .wasm_name = "div",
    },
    // FIXME: need to support unsigned and signed!
    .{
        .sym = syms.@"==",
        .wasm_name = "eq",
        .result_type = primitive_types.bool_,
        .signless = true,
    },
    // FIXME restore
    .{
        .sym = syms.@"!=",
        .wasm_name = "ne",
        .result_type = primitive_types.bool_,
        .signless = true,
    },
    .{
        .sym = syms.@"<",
        .wasm_name = "lt",
        .result_type = primitive_types.bool_,
    },
    .{
        .sym = syms.@"<=",
        .wasm_name = "le",
        .result_type = primitive_types.bool_,
    },
    .{
        .sym = syms.@">",
        .wasm_name = "gt",
        .result_type = primitive_types.bool_,
    },
    .{
        .sym = syms.@">=",
        .wasm_name = "ge",
        .result_type = primitive_types.bool_,
    },
    .{
        .sym = syms.@"and",
        .wasm_name = "and",
        .int_only = true,
        .result_type = primitive_types.bool_,
        .signless = true,
    },
    .{
        .sym = syms.@"or",
        .wasm_name = "or",
        .int_only = true,
        .result_type = primitive_types.bool_,
        .signless = true,
    },
};

const BinaryenHelper = struct {
    var alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var type_map: std.AutoHashMapUnmanaged(Type, byn.c.BinaryenType) = .{};

    pub fn getType(graphl_type: Type) byn.c.BinaryenType {
        return type_map.get(graphl_type) orelse std.debug.panic("No binaryen type registered for graphl type '{s}'", .{graphl_type.name});
    }
};

fn constructor() callconv(.C) void {
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.i32_, byn.c.BinaryenTypeInt32()) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.i64_, byn.c.BinaryenTypeInt64()) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.u32_, byn.c.BinaryenTypeInt32()) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.u64_, byn.c.BinaryenTypeInt64()) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.f32_, byn.c.BinaryenTypeFloat32()) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.f64_, byn.c.BinaryenTypeFloat64()) catch unreachable;

    // FIXME: bytes should have custom width in arrays! they shouldn't take 4 bytes...
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.byte, byn.c.BinaryenTypeInt32()) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.bool_, byn.c.BinaryenTypeInt32()) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.rgba, byn.c.BinaryenTypeInt32()) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.code, byn.c.BinaryenTypeStringref()) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.char_, byn.c.BinaryenTypeInt32()) catch unreachable;
    // FIXME: should symbols really be a string?
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.symbol, byn.c.BinaryenTypeStringref()) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.void, byn.c.BinaryenTypeNone()) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.string, byn.c.BinaryenTypeStringref()) catch unreachable;

    var vec3_parts = [3]byn.c.BinaryenType{
        byn.c.BinaryenTypeFloat64(),
        byn.c.BinaryenTypeFloat64(),
        byn.c.BinaryenTypeFloat64(),
    };

    BinaryenHelper.type_map.putNoClobber(
        BinaryenHelper.alloc.allocator(),
        primitive_types.vec3,
        byn.c.BinaryenTypeCreate(&vec3_parts, @intCast(vec3_parts.len)),
    ) catch unreachable;
}

// FIXME: idk if this works in wasm
export const _compiler_init_array: [1]*const fn () callconv(.C) void linksection(".init_array") = .{&constructor};

const Compilation = struct {
    // FIXME: consider making this an owned instance, why is it a pointer?
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

    module: *byn.Module,
    arena: std.heap.ArenaAllocator,
    user_context: struct {
        funcs: *const std.SinglyLinkedList(UserFunc),
        func_map: std.StringHashMapUnmanaged(*UserFunc),
    },

    // FIXME: support multiple diagnostics
    diag: *Diagnostic,

    pub fn init(
        alloc: std.mem.Allocator,
        env: *Env,
        maybe_user_funcs: ?*const std.SinglyLinkedList(UserFunc),
        in_diag: *Diagnostic,
    ) !@This() {
        var result = @This(){
            .arena = std.heap.ArenaAllocator.init(alloc),
            .diag = in_diag,
            .env = env,
            .module = byn.Module.init(),
            .user_context = .{
                .funcs = maybe_user_funcs orelse &empty_user_funcs,
                .func_map = undefined,
            },
        };

        var func_map: std.StringHashMapUnmanaged(*UserFunc) = .{};
        errdefer func_map.deinit(result.arena.allocator());

        if (maybe_user_funcs) |user_funcs| {
            var next = user_funcs.first;
            while (next) |cursor| : (next = cursor.next) {
                // NOTE: I _think_ this is a valid use of an arena that is about to be copied...
                try func_map.putNoClobber(result.arena.allocator(), cursor.data.node.name, &cursor.data);
            }
        }

        result.user_context.func_map = func_map;

        result.module.setFeatures(
            byn.Features.set(&.{
                byn.Features.GC(),
                byn.Features.MutableGlobals(),
                byn.Features.ReferenceTypes(),
                byn.Features.Multivalue(),
                byn.Features.Strings(),
            }),
        );

        return result;
    }

    pub fn deinit(self: *@This()) void {
        // NOTE: this is a no-op because of the arena
        // FIXME: any remaining func_types/func_decls values must be freed!
        //self.deferred.func_decls.deinit(alloc);
        //self.deferred.func_types.deinit(alloc);
        //self.env.deinit(self.arena.allocator());
        self.module.deinit();
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

        var local_names = std.ArrayList([:0]const u8).init(alloc);
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

        const param_names = try alloc.alloc([:0]const u8, func_bindings.len);
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

    fn compileMeta(self: *@This(), sexp: *const Sexp) !bool {
        _ = self;

        if (sexp.value != .list) return false;
        if (sexp.value.list.items.len == 0) return false;
        if (sexp.value.list.items[0].value != .symbol) return error.NonSymbolHead;
        if (sexp.value.list.items[0].value.symbol.ptr != syms.meta.value.symbol.ptr) return false;
        if (sexp.value.list.items.len < 3) return error.BadMetaSize;
        if (sexp.value.list.items[1].value != .symbol) return error.NonSymbolMetaProperty;
        const property = sexp.value.list.items[1].value.symbol;
        if (property.ptr != syms.version.value.symbol.ptr) return error.NonVersionMetaProperty;
        if (sexp.value.list.items[2].value != .int) return error.NonIntegerVersion;
        if (sexp.value.list.items[2].value.int != 1) return error.UnsupportedVersion;

        return true;
    }

    fn compileImport(self: *@This(), sexp: *const Sexp) !bool {
        if (sexp.value != .list) return false;
        if (sexp.value.list.items.len == 0) return false;
        if (sexp.value.list.items[0].value != .symbol) return error.NonSymbolHead;
        if (sexp.value.list.items[0].value.symbol.ptr != syms.import.value.symbol.ptr) return false;
        if (sexp.value.list.items[1].value != .symbol) return error.NonSymbolBinding;
        if (sexp.value.list.items[2].value != .ownedString) return error.NonStringPackagePath;

        const import_binding = sexp.value.list.items[1].value.symbol;

        const imported = try self.analyzeImportAtPath(sexp.value.list.items[2].value.ownedString);

        const node_desc = try self.arena.allocator().create(graphl_builtin.BasicNodeDesc);

        node_desc.* = .{
            .name = import_binding,
            .kind = .func,
            .inputs = imported.inputs,
            .outputs = imported.outputs,
        };

        // we must use the same allocator that env is deinited with!
        _ = try self.env.addNode(self.arena.child_allocator, graphl_builtin.basicNode(node_desc));

        return true;
    }

    const ImportInfo = struct {
        inputs: []Pin = &.{},
        outputs: []Pin = &.{},
    };

    fn analyzeImportAtPath(self: *@This(), path: []const u8) !ImportInfo {
        const first_slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.ImportPathWithoutNamespace;
        // TODO: support hierarchy
        const namespace = path[0..first_slash];

        if (!std.mem.eql(u8, namespace, "host")) return error.OnlyHostFuncImportsSupported;

        const item_name = path[first_slash + 1 ..];

        const user_func = self.user_context.func_map.get(item_name) orelse return error.NoSuchHostFunc;

        return ImportInfo{
            .inputs = user_func.node.inputs,
            .outputs = user_func.node.outputs,
        };
    }

    fn compileVar(self: *@This(), sexp: *const Sexp) !bool {
        _ = self;

        if (sexp.value != .list) return false;
        if (sexp.value.list.items.len == 0) return false;
        if (sexp.value.list.items[0].value != .symbol) return error.NonSymbolHead;

        if (sexp.value.list.items[0].value.symbol.ptr != syms.define.value.symbol.ptr) return false;

        if (sexp.value.list.items[1].value != .symbol) return error.NonSymbolBinding;

        const var_name = sexp.value.list.items[1].value.symbol;
        //const params = sexp.value.list.items[1].value.list.items[1..];
        const var_name_mangled = var_name;
        _ = var_name_mangled;

        //byn.Expression;

        return true;
    }

    fn compileTypeOf(self: *@This(), sexp: *const Sexp) !bool {
        if (sexp.value != .list) return false;
        if (sexp.value.list.items.len == 0) return error.TypeDeclListEmpty;
        if (sexp.value.list.items[0].value != .symbol) return error.NonSymbolHead;
        if (sexp.value.list.items[0].value.symbol.ptr != syms.typeof.value.symbol.ptr) return false;

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

    fn finishCompileTypedFunc(self: *@This(), name: [:0]const u8, func_decl: DeferredFuncDeclInfo, func_type: DeferredFuncTypeInfo) !void {
        // TODO: configure std.log.debug
        //std.log.debug("compile func: '{s}'\n", .{name});
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

        std.debug.assert(func_decl.body_exprs.len >= 1);

        var label_map = std.StringHashMap(ExprContext.LabelData).init(alloc);
        defer label_map.deinit();

        var prologue = std.ArrayList(Sexp).init(alloc);
        defer prologue.deinit();

        // TODO: use @FieldType
        var post_analysis_locals: std.StringArrayHashMapUnmanaged(ExprContext.LocalInfo) = .{};
        defer post_analysis_locals.deinit(self.arena.allocator());

        // NOTE: gross, simplify me
        const local_types = try alloc.alloc(byn.Type, complete_func_type_desc.func_type.?.local_types.len + prologue.items.len);
        for (local_types[0..complete_func_type_desc.func_type.?.local_types.len], complete_func_type_desc.func_type.?.local_types) |*out_local_type, local_type|
            out_local_type.* = @enumFromInt(BinaryenHelper.getType(local_type));
        for (local_types[complete_func_type_desc.func_type.?.local_types.len..]) |*out_local_type|
            out_local_type.* = .i32;

        var body_exprs = try std.ArrayListUnmanaged(*byn.Expression).initCapacity(self.arena.allocator(), func_decl.body_exprs.len);
        // FIXME: is this valid use of API?
        defer body_exprs.deinit(self.arena.allocator());

        // FIXME: consider adding to a fresh environment as we compile instead of
        // reusing an environment populated by the caller

        //export_val_sexp.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "${s}", .{complete_func_type_desc.name}) } };

        // FIXME:
        // analyze the code to know ahead of time the return type and local count

        var result_type: ?Type = null;
        // FIXME: not used?
        var result_type_wasm: ?byn.c.BinaryenType = null;

        for (func_decl.body_exprs, 0..) |*body_expr, i| {
            var expr_ctx = ExprContext{
                .locals = &post_analysis_locals,
                .label_map = &label_map,
                .param_names = func_decl.param_names,
                .param_types = func_type.param_types,
                .prologue = &prologue,
                .frame = .{},
                .is_captured = i == func_decl.body_exprs.len - 1 or body_expr.label != null, // only capture the last expression or labeled
            };
            var expr_fragment = try self.compileExpr(body_expr, &expr_ctx);
            errdefer expr_fragment.deinit(alloc);
            body_exprs.appendAssumeCapacity(expr_fragment.expr);

            // TODO: only need to set this on the last one
            result_type = expr_fragment.resolved_type;
        }

        // FIXME: use a compound result type to avoid this check
        std.debug.assert(func_type.result_types.len == 1);
        if (result_type.? != func_type.result_types[0]) {
            //std.log.warn("body_fragment:\n{}\n", .{Sexp{ .value = .{ .module = expr_fragment.values } }});
            std.log.warn("type: '{s}' doesn't match '{s}'", .{ result_type.?.name, func_type.result_types[0].name });
            // FIXME/HACK: re-enable but disabling now to awkwardly allow for type promotion
            //return error.ReturnTypeMismatch;
        }

        var is_compound_result_type: bool = undefined;

        // now that we have the result type:
        if (result_type != null) {
            result_type_wasm = BinaryenHelper.getType(result_type.?);

            // TODO: support user compound types
            is_compound_result_type = _: {
                inline for (comptime std.meta.declarations(graphl_builtin.compound_builtin_types)) |decl| {
                    const type_ = @field(graphl_builtin.compound_builtin_types, decl.name);
                    if (type_ == result_type.?)
                        break :_ true;
                }
                break :_ false;
            };
        } else {
            return error.ResultTypeNotDetermined;
        }

        // FIXME: add epilogue
        // add epilogue
        // {
        //     // FIXME: parse this and insert substitutions at comptime!
        //     const epilogue_src =
        //         \\(global.set $__grappl_vstkp
        //         \\            (local.get $__frame_start))
        //         \\
        //     ;
        //     var diag = SexpParser.Diagnostic{ .source = epilogue_src };
        //     var epilogue_code = SexpParser.parse(alloc, epilogue_src, &diag) catch {
        //         std.log.err("diag={}", .{diag});
        //         @panic("failed to parse temp non-comptime epilogue_src");
        //     };
        //     // FIXME: allow moving list out of sexp
        //     defer epilogue_code.value.module.deinit();
        //     try impl_sexp.value.list.appendSlice(epilogue_code.value.module.items);
        // }

        // FIXME
        if (body_exprs.items.len == 0) return error.EmptyBody;

        //const body = try byn.Expression.block(self.module, "impl", body_exprs.items, byn.Type.auto());
        const body = try byn.Expression.block(self.module, "impl", body_exprs.items, .i32);

        const param_types = try self.arena.allocator().alloc(byn.c.BinaryenType, complete_func_type_desc.func_type.?.param_types.len);
        defer self.arena.allocator().free(param_types); // FIXME: what is the binaryen ownership model
        for (param_types, complete_func_type_desc.func_type.?.param_types) |*wasm_t, graphl_t| {
            wasm_t.* = BinaryenHelper.getType(graphl_t);
        }
        const param_type_byn: byn.c.BinaryenType = byn.c.BinaryenTypeCreate(param_types.ptr, @intCast(param_types.len));

        const result_types = try self.arena.allocator().alloc(byn.c.BinaryenType, complete_func_type_desc.func_type.?.result_types.len);
        defer self.arena.allocator().free(result_types); // FIXME: what is the binaryen ownership model?
        for (result_types, complete_func_type_desc.func_type.?.result_types) |*wasm_t, graphl_t| {
            wasm_t.* = BinaryenHelper.getType(graphl_t);
        }
        const result_type_byn: byn.c.BinaryenType = byn.c.BinaryenTypeCreate(result_types.ptr, @intCast(result_types.len));

        const func = self.module.addFunction(
            name,
            @enumFromInt(param_type_byn),
            @enumFromInt(result_type_byn),
            local_types,
            body,
        );

        _ = func;

        _ = byn.c.BinaryenAddFunctionExport(self.module.c(), name, name);
    }

    /// A fragment of compiled code and the type of its final variable
    const Fragment = struct {
        /// values used to reference this fragment
        expr: *byn.Expression,
        /// offset in the stack frame for the value in this fragment
        frame_offset: u32 = 0,
        resolved_type: Type = graphl_builtin.empty_type,
    };

    // find the nearest super type (if any) of two types
    fn resolvePeerType(a: Type, b: Type) !Type {
        if (a == graphl_builtin.empty_type)
            return b;

        if (b == graphl_builtin.empty_type)
            return a;

        if (a == b)
            return a;

        // REPORT: zig can't switch on constant pointers
        const resolved_type = _: {
            if (a == primitive_types.bool_) {
                if (b == primitive_types.bool_) break :_ primitive_types.bool_;
                if (b == primitive_types.i32_) break :_ primitive_types.i32_;
                if (b == primitive_types.i64_) break :_ primitive_types.i64_;
                if (b == primitive_types.f32_) break :_ primitive_types.f32_;
                if (b == primitive_types.f64_) break :_ primitive_types.f64_;
            } else if (a == primitive_types.i32_) {
                if (b == primitive_types.bool_) break :_ primitive_types.i32_;
                if (b == primitive_types.i32_) break :_ primitive_types.i32_;
                if (b == primitive_types.i64_) break :_ primitive_types.i64_;
                if (b == primitive_types.f32_) break :_ primitive_types.f32_;
                if (b == primitive_types.f64_) break :_ primitive_types.f64_;
            } else if (a == primitive_types.i64_) {
                if (b == primitive_types.bool_) break :_ primitive_types.i64_;
                if (b == primitive_types.i32_) break :_ primitive_types.i64_;
                if (b == primitive_types.i64_) break :_ primitive_types.i64_;
                if (b == primitive_types.f32_) break :_ primitive_types.f32_;
                if (b == primitive_types.f64_) break :_ primitive_types.f64_;
            } else if (a == primitive_types.f32_) {
                if (b == primitive_types.bool_) break :_ primitive_types.f32_;
                if (b == primitive_types.i32_) break :_ primitive_types.f32_;
                if (b == primitive_types.i64_) break :_ primitive_types.f32_;
                if (b == primitive_types.f32_) break :_ primitive_types.f32_;
                if (b == primitive_types.f64_) break :_ primitive_types.f64_;
            } else if (a == primitive_types.f64_) {
                if (b == primitive_types.bool_) break :_ primitive_types.f64_;
                if (b == primitive_types.i32_) break :_ primitive_types.f64_;
                if (b == primitive_types.i64_) break :_ primitive_types.f64_;
                if (b == primitive_types.f32_) break :_ primitive_types.f64_;
                if (b == primitive_types.f64_) break :_ primitive_types.f64_;
            }
            std.log.err("unimplemented peer type resolution: {s} & {s}", .{ a.name, b.name });
            std.debug.panic("unimplemented peer type resolution: {s} & {s}", .{ a.name, b.name });
        };

        return resolved_type;
    }

    // TODO: use an actual type graph/tree and search in it
    // promote the type of a fragment, adding necessary conversion code to the fragment
    fn promoteToTypeInPlace(self: *@This(), fragment: *Fragment, target_type: Type) !void {
        var i: usize = 0;
        const MAX_ITERS = 128;
        while (fragment.resolved_type != target_type) : (i += 1) {
            if (i > MAX_ITERS) {
                std.log.err("max iters resolving types: {s} -> {s}", .{ fragment.resolved_type.name, target_type.name });
                std.debug.panic("max iters resolving types: {s} -> {s}", .{ fragment.resolved_type.name, target_type.name });
            }

            if (fragment.resolved_type == primitive_types.bool_) {
                fragment.resolved_type = primitive_types.i32_;
                continue;
            }

            var op: byn.Expression.Op = undefined;

            if (fragment.resolved_type == primitive_types.i32_) {
                op = byn.Expression.Op.extendSInt32();
                fragment.resolved_type = primitive_types.i64_;
            } else if (fragment.resolved_type == primitive_types.i64_) {
                op = byn.Expression.Op.convertSInt64ToFloat32();
                fragment.resolved_type = primitive_types.f32_;
            } else if (fragment.resolved_type == primitive_types.u32_) {
                op = byn.Expression.Op.extendUInt32();
                fragment.resolved_type = primitive_types.i64_;
            } else if (fragment.resolved_type == primitive_types.u64_) {
                op = byn.Expression.Op.convertUInt64ToFloat32();
                fragment.resolved_type = primitive_types.f32_;
            } else if (fragment.resolved_type == primitive_types.f32_) {
                op = byn.Expression.Op.promoteFloat32();
                fragment.resolved_type = primitive_types.f64_;
            } else {
                std.log.err("unimplemented type promotion: {s} -> {s}", .{ fragment.resolved_type.name, target_type.name });
                std.debug.panic("unimplemented type promotion: {s} -> {s}", .{ fragment.resolved_type.name, target_type.name });
            }

            fragment.expr = byn.Expression.unaryOp(self.module, op, fragment.expr);
        }
    }

    // resolve the peer type of the fragments, then augment the fragment to be casted to that resolved peer
    fn resolvePeerTypesWithPromotions(self: *@This(), a: *Fragment, b: *Fragment) !Type {
        if (a.resolved_type == graphl_builtin.empty_type)
            return b.resolved_type;

        if (b.resolved_type == graphl_builtin.empty_type)
            return a.resolved_type;

        if (a.resolved_type == b.resolved_type)
            return a.resolved_type;

        // REPORT: zig can't switch on constant pointers
        const resolved_type = try resolvePeerType(a.resolved_type, b.resolved_type);

        inline for (&.{ a, b }) |fragment| {
            try self.promoteToTypeInPlace(fragment, resolved_type);
        }

        return resolved_type;
    }

    const StackFrame = struct {
        byte_size: usize = 0,
    };

    const ExprContext = struct {
        type: ?Type = null,
        param_names: []const []const u8,
        param_types: []const Type,

        /// whether the return value of the expression isn't discarded
        is_captured: bool,
        frame: StackFrame,

        locals: *std.StringArrayHashMapUnmanaged(LocalInfo),

        /// to append setup code to
        prologue: *std.ArrayList(Sexp),
        /// to hold label references
        label_map: *std.StringHashMap(LabelData),
        next_local_index: u32 = 0,

        const LocalInfo = struct {
            index: u32,
            type: Type,
        };

        const LabelData = struct {
            fragment: Fragment,
            /// needed e.g. if it's a macro context
            sexp: *const Sexp,
        };

        fn nextAnonymousLocalName(self: *@This()) [:0]const u8 {
            // TODO: use stackMaxesPrint
            var buf: [128]u8 = undefined;
            const sym = std.fmt.bufPrint(&buf, "_$$local{}", .{self.next_local_index}) catch unreachable;
            self.next_local_index += 1;
            return pool.getSymbol(sym);
        }

        /// sometimes, e.g. when creating a vstack slot, we need a local to
        /// hold the pointer to it
        /// @returns a Sexp{.value = .symbol}
        pub fn addLocal(self: *@This(), ctx: *Compilation, type_: Type, symbol: ?[:0]const u8) !u32 {
            try self.locals.put(
                ctx.arena.allocator(),
                symbol orelse self.nextAnonymousLocalName(),
                .{
                    .index = @intCast(self.locals.count()),
                    .type = type_,
                },
            );
            return @intCast(self.locals.count() - 1);
        }
    };

    const CompileExprError = std.mem.Allocator.Error || error{
        UndefinedSymbol,
        UnimplementedMultiResultHostFunc,
        UnhandledCall,
    };

    // TODO: figure out how to ergonomically skip compiling labeled exprs until they are referenced...
    // TODO: take a diagnostic
    fn compileExpr(
        self: *@This(),
        code_sexp: *const Sexp,
        /// not const because we may be expanding the frame to include this value
        context: *ExprContext,
    ) CompileExprError!Fragment {
        std.log.debug("compiling expr: '{}'\n", .{code_sexp});

        // FIXME: destroy this
        // HACK: oh god this is bad...
        if (code_sexp.label != null and code_sexp.value == .list
        //
        and code_sexp.value.list.items.len > 0
        //
        and code_sexp.value.list.items[0].value == .symbol
        //
        and _: {
            const sym = code_sexp.value.list.items[0].value.symbol;
            inline for (&.{ "SELECT", "WHERE", "FROM" }) |hack| {
                if (std.mem.eql(u8, sym, hack))
                    break :_ true;
            }
            break :_ false;
        }) {
            const fragment = Fragment{
                .expr = @ptrCast(byn.c.BinaryenNop(self.module.c())),
                .resolved_type = primitive_types.code,
            };

            const entry = try context.label_map.getOrPut(code_sexp.label.?[2..]);
            std.debug.assert(!entry.found_existing);

            entry.value_ptr.* = .{
                .fragment = fragment,
                .sexp = code_sexp,
            };

            return fragment;
        }

        const fragment = try self._compileExpr(code_sexp, context);

        if (code_sexp.label) |label| {
            // HACK: we know the label is "#!{s}"
            const entry = try context.label_map.getOrPut(label[2..]);
            std.debug.assert(!entry.found_existing);

            // calls already have a local
            const local_idx = try context.addLocal(self, fragment.resolved_type, null);

            const ref_code_fragment = Fragment{
                .expr = byn.Expression.localGet(self.module, local_idx, @enumFromInt(BinaryenHelper.getType(fragment.resolved_type))),
                .resolved_type = fragment.resolved_type,
            };

            entry.value_ptr.* = .{
                .fragment = ref_code_fragment,
                .sexp = code_sexp,
            };

            // FIXME: prevoiusly in addition to getting the label, we replaced the incoming fragment with
            // just getting this
            // try fragment.values.ensureUnusedCapacity(1);
            // const set = fragment.values.addOneAssumeCapacity();
            // set.* = Sexp.newList(alloc);
            // try set.value.list.ensureTotalCapacityPrecise(2);
            // set.value.list.appendAssumeCapacity(wat_syms.ops.@"local.set");
            // set.value.list.appendAssumeCapacity(local_ptr_sym);
        }

        return fragment;
    }

    fn stackAllocIntrinsicCode(
        self: *@This(),
        alloc: *std.heap.ArenaAllocator,
        comptime IntrinsicType: type,
        //data: ?IntrinsicType,
    ) std.mem.Allocator.Error!Fragment {
        var alloc_code = _: {
            const src = try std.fmt.allocPrint(alloc,
                \\;; push slot pointer onto locals stack
                \\(global.get $__grappl_vstkp)
                \\
                \\;; now increment the stack pointer to the next memory location
                \\(global.set $__grappl_vstkp
                \\            (i32.add (global.get $__grappl_vstkp)
                \\                     (i32.const {0})))
                // FIXME: consider a check for stack overflow
            , .{
                @sizeOf(IntrinsicType),
            });
            // FIXME: can't free cuz the Sexp point to this memory
            // defer alloc.free(src);
            var diag = SexpParser.Diagnostic{ .source = src };
            break :_ SexpParser.parse(alloc, src, &diag) catch {
                std.log.err("diag={}", .{diag});
                @panic("failed to parse temp non-comptime src");
            };
        };
        errdefer alloc_code.deinit(alloc);

        // TODO: implement setting intrinsics
        // var set_code: std.ArrayListUnmanaged(Sexp) = .{};
        // defer set_code.deinit(alloc);

        // FIXME: get inline field count at comptime to avoid allocs
        // set_code.list.ensureTotalCapacityPrecise(2 + );

        // const Local = struct {
        //     fn writeData(
        //         comptime T: type,
        //         value: T,
        //         depth: usize,
        //         _set_code: *std.ArrayListUnmanaged(Sexp),
        //     ) !usize {
        //         inline for (std.meta.fields(T)) |field| {
        //             switch (@typeInfo(field.type)) {
        //                 .Struct => {
        //                     try stackAllocIntrinsicCode(alloc, field.type, @field(value, field.name), depth);
        //                 },
        //                 .Int, .Float, .Bool => {
        //                     const src = try std.fmt.allocPrint(alloc,
        //                         \\;; push slot pointer onto locals stack
        //                         \\(i32.store (i32.add (global.get $__grappl_vstkp)
        //                         \\                    (i32.const {0}))
        //                         \\           {1}
        //                         \\
        //                     , .{
        //                         @sizeOf(field.type),
        //                     });
        //                     defer alloc.free(src);
        //                     var diag = SexpParser.Diagnostic{ .source = src };
        //                     const parsed = SexpParser.parse(alloc, src, &diag) catch {
        //                         std.log.err("diag={}", .{diag});
        //                         @panic("failed to parse temp non-comptime src");
        //                     };
        //                     try _set_code.appendSlice(alloc, try parsed.value.module.toOwnedSlice());
        //                 },
        //                 else => @compileError("field has unsupported type: " ++ @typeName(field.type)),
        //             }
        //         }
        //     }
        // };

        // if (data) |d| {
        //     Local.writeData(d);
        // }

        // try alloc_code.value.module.insertSlice(1, set_code.items);

        // FIXME: nop
        return Fragment{
            //.frame_offset = @sizeOf(IntrinsicType),
            .expr = @ptrCast(byn.c.BinaryenNop(self.module.c())),
            .resolved_type = graphl_builtin.empty_type,
        };
    }

    // TODO: calls to a graph function pass a return address as a parameter if the return type
    // is not a primitive/singleton type (u32, f32, i64, etc)
    fn _compileExpr(
        self: *@This(),
        code_sexp: *const Sexp,
        /// not const because we may be expanding the frame to include this value
        context: *ExprContext,
    ) CompileExprError!Fragment {
        const alloc = self.arena.allocator();

        var result = Fragment{
            .expr = @ptrCast(byn.c.BinaryenNop(self.module.c())),
        };

        // FIXME: replace nullable context.type with empty_type
        if (context.type != null and context.type.? == primitive_types.code) {
            var bytes = std.ArrayList(u8).init(alloc);
            defer bytes.deinit();

            const expr_sexp = switch (code_sexp.value) {
                .symbol => |sym| _: {
                    break :_ if (context.label_map.get(sym)) |label| label.sexp else null;
                },
                else => null,
            } orelse code_sexp;

            var quote_json_root = json.ObjectMap.init(alloc);
            defer quote_json_root.deinit();

            try quote_json_root.put("entry", try expr_sexp.jsonValue(alloc));

            var labels_json = json.ObjectMap.init(alloc);
            defer labels_json.deinit();
            {
                var label_iter = context.label_map.iterator();
                while (label_iter.next()) |entry| {
                    try labels_json.put(entry.key_ptr.*, try entry.value_ptr.sexp.jsonValue(alloc));
                }
            }
            try quote_json_root.put("labels", json.Value{ .object = labels_json });

            // FIXME: wasteful to translate to an in-memory jsonValue, just write it directly as JSON to the stream
            var jws = std.json.writeStream(bytes.writer(), .{ .escape_unicode = true });
            try (json.Value{ .object = quote_json_root }).jsonStringify(&jws);
            try bytes.append(0);

            // TODO: check lifetime of binaryen expressions...
            // FIXME: figure out binaryen errors
            result.expr = byn.Expression.stringConst(self.module, @ptrCast(bytes.items)) catch unreachable;

            return result;
        }

        switch (code_sexp.value) {
            .list => |v| {
                std.debug.assert(v.items.len >= 1);
                const func = &v.items[0];
                std.debug.assert(func.value == .symbol);

                if (func.value.symbol.ptr == syms.@"return".value.symbol.ptr
                //
                or func.value.symbol.ptr == syms.begin.value.symbol.ptr) {
                    // FIXME: we can drop this if we don't use the arena
                    var body_exprs = try std.ArrayListUnmanaged(*byn.Expression).initCapacity(self.arena.allocator(), v.items.len - 1);
                    // FIXME: is this valid use of API?
                    defer body_exprs.deinit(self.arena.allocator());

                    for (v.items[1..], 1..) |*expr, i| {
                        var subcontext = ExprContext{
                            .type = context.type,
                            .locals = context.locals,
                            .param_names = context.param_names,
                            .param_types = context.param_types,
                            .prologue = context.prologue,
                            .frame = context.frame,
                            .label_map = context.label_map,
                            .is_captured = i == v.items.len - 1 or expr.label != null, // only capture the last expression or labeled
                        };
                        var compiled = try self.compileExpr(expr, &subcontext);
                        result.resolved_type = try self.resolvePeerTypesWithPromotions(&result, &compiled);
                        body_exprs.appendAssumeCapacity(compiled.expr);
                    }

                    result.expr = @ptrCast(byn.Expression.block(self.module, "impl", body_exprs.items, byn.Type.auto()) catch unreachable);
                    return result;
                }

                // call host functions
                const func_node_desc = self.env.getNode(func.value.symbol) orelse {
                    std.log.err("while in:\n{}\n", .{code_sexp});
                    std.log.err("undefined symbol1: '{}'\n", .{func});
                    self.diag.err = .{ .UndefinedSymbol = func.value.symbol };
                    return error.UndefinedSymbol;
                };

                const arg_fragments = try alloc.alloc(Fragment, v.items.len - 1);
                // initialize as empty to prevent errdefer from freeing corrupt data
                for (arg_fragments) |*frag| frag.* = Fragment{ .expr = @ptrCast(byn.c.BinaryenNop(self.module.c())) };

                // TODO: also undo context state
                // FIXME: do we need to deinit the binaryen IR tree in the error case?
                defer alloc.free(arg_fragments);

                const if_inputs = [_]Pin{
                    Pin{
                        .name = "condition",
                        .kind = .{ .primitive = .{ .value = primitive_types.bool_ } },
                    },
                    Pin{
                        .name = "then",
                        .kind = .{ .primitive = .{ .value = graphl_builtin.empty_type } },
                    },
                    Pin{
                        .name = "else",
                        .kind = .{ .primitive = .{ .value = graphl_builtin.empty_type } },
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
                        .param_names = context.param_names,
                        .param_types = context.param_types,
                        .prologue = context.prologue,
                        .locals = context.locals,
                        .frame = context.frame,
                        .label_map = context.label_map,
                        .is_captured = context.is_captured,
                    };
                    arg_fragment.* = try self.compileExpr(&arg_src, &subcontext);
                }

                // FIXME: support set!
                // if (func.value.symbol.ptr == syms.@"set!".value.symbol.ptr) {
                //     std.debug.assert(arg_fragments.len == 2);

                //     std.debug.assert(arg_fragments[0].values.items.len == 1);
                //     std.debug.assert(arg_fragments[0].values.items[0].value == .list);
                //     std.debug.assert(arg_fragments[0].values.items[0].value.list.items.len == 2);
                //     std.debug.assert(arg_fragments[0].values.items[0].value.list.items[0].value == .symbol);
                //     std.debug.assert(arg_fragments[0].values.items[0].value.list.items[1].value == .symbol);

                //     result.resolved_type = try self.resolvePeerTypesWithPromotions(&arg_fragments[0], &arg_fragments[1]);

                //     // FIXME: leak
                //     const set_sym = arg_fragments[0].values.items[0].value.list.items[1];

                //     std.debug.assert(arg_fragments[1].values.items.len == 1);
                //     const set_val = arg_fragments[1].values.items[0];

                //     try result.values.ensureTotalCapacityPrecise(1);
                //     const wasm_op = result.values.addOneAssumeCapacity();
                //     wasm_op.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                //     try wasm_op.value.list.ensureTotalCapacityPrecise(3);
                //     wasm_op.value.list.addOneAssumeCapacity().* = wat_syms.ops.@"local.set";

                //     wasm_op.value.list.addOneAssumeCapacity().* = set_sym;
                //     // TODO: more idiomatic move out data
                //     arg_fragments[0].values.items[0] = Sexp{ .value = .void };

                //     wasm_op.value.list.addOneAssumeCapacity().* = set_val;
                //     // TODO: more idiomatic move out data
                //     arg_fragments[1].values.items[0] = Sexp{ .value = .void };

                //     return result;
                // }

                // FIXME: support if
                // if (func.value.symbol.ptr == syms.@"if".value.symbol.ptr) {
                //     std.debug.assert(arg_fragments.len == 3);

                //     result.resolved_type = try self.resolvePeerTypesWithPromotions(&arg_fragments[1], &arg_fragments[2]);

                //     try result.values.ensureTotalCapacityPrecise(1);
                //     const wasm_op = result.values.addOneAssumeCapacity();
                //     wasm_op.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                //     try wasm_op.value.list.ensureTotalCapacityPrecise(5);
                //     wasm_op.value.list.addOneAssumeCapacity().* = syms.@"if";
                //     const result_type = wasm_op.value.list.addOneAssumeCapacity();
                //     const cond = wasm_op.value.list.addOneAssumeCapacity();
                //     const consequence = wasm_op.value.list.addOneAssumeCapacity();
                //     const alternative = wasm_op.value.list.addOneAssumeCapacity();

                //     result_type.* = Sexp.newList(alloc);

                //     std.debug.assert(arg_fragments[0].values.items.len == 1);
                //     cond.* = arg_fragments[0].values.items[0];
                //     arg_fragments[0].values.items[0] = Sexp{ .value = .void };

                //     consequence.* = Sexp.newList(alloc);
                //     try consequence.value.list.ensureTotalCapacityPrecise(1 + arg_fragments[1].values.items.len);
                //     consequence.value.list.addOneAssumeCapacity().* = wat_syms.then;
                //     for (arg_fragments[1].values.items) |*then_code| {
                //         consequence.value.list.addOneAssumeCapacity().* = then_code.*;
                //         then_code.* = Sexp{ .value = .void };
                //     }

                //     alternative.* = Sexp.newList(alloc);
                //     try alternative.value.list.ensureTotalCapacityPrecise(1 + arg_fragments[2].values.items.len);
                //     alternative.value.list.addOneAssumeCapacity().* = wat_syms.@"else";
                //     for (arg_fragments[2].values.items) |*else_code| {
                //         alternative.value.list.addOneAssumeCapacity().* = else_code.*;
                //         else_code.* = Sexp{ .value = .void };
                //     }

                //     try result_type.value.list.ensureTotalCapacityPrecise(2);
                //     result_type.value.list.addOneAssumeCapacity().* = wat_syms.result;
                //     result_type.value.list.addOneAssumeCapacity().* = Sexp{ .value = .{ .symbol = result.resolved_type.wasm_type.? } };

                //     return result;
                // }

                inline for (&binaryop_builtins) |builtin_op| {
                    if (func.value.symbol.ptr == builtin_op.sym.value.symbol.ptr) {
                        var op: byn.Expression.Op = undefined;

                        var resolved_type = graphl_builtin.empty_type;

                        for (arg_fragments) |*arg_fragment| {
                            resolved_type = try resolvePeerType(resolved_type, arg_fragment.resolved_type);
                        }

                        std.debug.assert(arg_fragments.len == 2);

                        for (arg_fragments) |*arg_fragment| {
                            try self.promoteToTypeInPlace(arg_fragment, resolved_type);
                        }

                        //const left_arg_frag = &arg_fragments[0];
                        //const right_arg_frag = &arg_fragments[1];

                        var handled = false;

                        // FIXME: use a mapping to get the right type? e.g. a switch on type pointers would be nice
                        // but iirc that is broken
                        inline for (&.{
                            .{ primitive_types.i32_, "SInt32", false },
                            .{ primitive_types.i64_, "SInt64", false },
                            .{ primitive_types.u32_, "UInt32", false },
                            .{ primitive_types.u64_, "UInt64", false },
                            .{ primitive_types.f32_, "Float32", true },
                            .{ primitive_types.f64_, "Float64", true },
                        }) |type_info| {
                            const graphl_type, const type_byn_name, const is_float = type_info;
                            const float_type_but_int_op = @hasField(@TypeOf(builtin_op), "int_only") and is_float;
                            if (!handled and !float_type_but_int_op) {
                                if (resolved_type == graphl_type) {
                                    const signless = @hasField(@TypeOf(builtin_op), "signless");
                                    const opName = comptime if (signless and !is_float) builtin_op.wasm_name ++ type_byn_name[1..] else builtin_op.wasm_name ++ type_byn_name;
                                    op = @field(byn.Expression.Op, opName)();
                                    handled = true;
                                }
                            }
                        }

                        result.expr = byn.Expression.binaryOp(self.module, op, arg_fragments[0].expr, arg_fragments[1].expr);

                        // REPORT ME: try to prefer an else on the above for loop, currently couldn't get it to compile right
                        if (!handled) {
                            std.log.err("unimplemented type resolution: '{s}' for code:\n{s}\n", .{ result.resolved_type.name, code_sexp });
                            std.debug.panic("unimplemented type resolution: '{s}'", .{result.resolved_type.name});
                        }

                        if (@hasField(@TypeOf(builtin_op), "result_type")) {
                            result.resolved_type = builtin_op.result_type;
                        } else {
                            result.resolved_type = resolved_type;
                        }

                        return result;
                    }
                }

                // FIXME: make this work again
                // FIXME: this hacky interning-like code is horribly bug prone
                // FIXME: rename to standard library cuz it's also that
                // builtins with intrinsics
                // inline for (comptime std.meta.declarations(wat_syms.intrinsics)) |intrinsic_decl| {
                //     const intrinsic = @field(wat_syms.intrinsics, intrinsic_decl.name);
                //     const node_desc = intrinsic.node_desc;
                //     const outputs = node_desc.getOutputs();
                //     std.debug.assert(outputs.len == 1);
                //     std.debug.assert(outputs[0].kind == .primitive);
                //     std.debug.assert(outputs[0].kind.primitive == .value);
                //     result.resolved_type = outputs[0].kind.primitive.value;

                //     if (func.value.symbol.ptr == node_desc.name().ptr) {
                //         const instruct_count: usize = if (result.resolved_type == graphl_builtin.empty_type) 1 else 2;
                //         try result.values.ensureTotalCapacityPrecise(instruct_count);

                //         const wasm_call = result.values.addOneAssumeCapacity();
                //         wasm_call.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };

                //         const total_args = _: {
                //             var total_args_res: usize = 2; // start with 2 for (call $FUNC_NAME ...)
                //             for (arg_fragments) |arg_frag| total_args_res += arg_frag.values.items.len;
                //             break :_ total_args_res;
                //         };

                //         try wasm_call.value.list.ensureTotalCapacityPrecise(total_args);
                //         // FIXME: use types to determine
                //         wasm_call.value.list.addOneAssumeCapacity().* = wat_syms.call;
                //         wasm_call.value.list.addOneAssumeCapacity().* = intrinsic.wasm_sym;

                //         for (arg_fragments, node_desc.getInputs()) |*arg_fragment, input| {
                //             try self.promoteToTypeInPlace(arg_fragment, input.kind.primitive.value);
                //             wasm_call.value.list.appendSliceAssumeCapacity(arg_fragment.values.items);
                //             for (arg_fragment.values.items) |*subarg| {
                //                 // FIXME: implement move much more clearly
                //                 subarg.* = Sexp{ .value = .void };
                //             }
                //         }

                //         // FIXME: do any intrinsics need to be recalled without labels?
                //         // if (result.resolved_type != graphl_builtin.empty_type) {
                //         //     const local_result_ptr_sym = try context.addLocal(alloc, result.resolved_type);

                //         //     const consume_result = result.values.addOneAssumeCapacity();
                //         //     consume_result.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                //         //     try consume_result.value.list.ensureTotalCapacityPrecise(2);
                //         //     consume_result.value.list.appendAssumeCapacity(wat_syms.ops.@"local.set");
                //         //     consume_result.value.list.appendAssumeCapacity(local_result_ptr_sym);
                //         // }

                //         return result;
                //     }
                // }

                // FIXME: handle quote

                // FIXME: make this work again
                // ok, it must be a function in scope then (user or builtin)
                {
                    const outputs = func_node_desc.getOutputs();

                    // FIXME: horrible
                    const is_pure = outputs.len == 1 and outputs[0].kind == .primitive and outputs[0].kind.primitive == .value;
                    const is_simple_0_out_impure = outputs.len == 1 and outputs[0].kind == .primitive and outputs[0].kind.primitive == .exec;
                    const is_simple_1_out_impure = outputs.len == 2 and outputs[0].kind == .primitive and outputs[0].kind.primitive == .exec and outputs[1].kind == .primitive and outputs[1].kind.primitive == .value;

                    result.resolved_type =
                        if (is_pure) outputs[0].kind.primitive.value
                    //
                    else if (is_simple_0_out_impure)
                        graphl_builtin.empty_type
                        //
                    else if (is_simple_1_out_impure)
                        outputs[1].kind.primitive.value
                        //
                    else {
                        std.debug.print("func={s}\n", .{func_node_desc.name()});
                        return error.UnimplementedMultiResultHostFunc;
                    };

                    const requires_drop = result.resolved_type != graphl_builtin.empty_type and !context.is_captured;

                    const operands = try alloc.alloc(*byn.Expression, arg_fragments.len + @as(usize, if (requires_drop) 1 else 0));

                    defer alloc.free(operands); // FIXME: what is binaryen ownership model?

                    for (arg_fragments, operands) |arg_fragment, *operand| {
                        operand.* = arg_fragment.expr;
                    }

                    if (requires_drop) {
                        operands[operands.len - 1] = @ptrCast(byn.c.BinaryenDrop(
                            self.module.c(),
                            // FIXME: why does Drop take an argument?
                            byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(0)),
                        ));
                    }

                    result.expr = @ptrCast(byn.c.BinaryenCall(
                        self.module.c(),
                        func.value.symbol,
                        @ptrCast(operands.ptr),
                        @intCast(operands.len),
                        // FIXME: derive the result type
                        @intFromEnum(byn.Type.i32),
                    ));

                    return result;
                }

                // otherwise we have a non builtin
                std.log.err("unhandled call: {}", .{code_sexp});
                return error.UnhandledCall;
            },

            .int => |v| {
                result.resolved_type = primitive_types.i32_;
                result.expr = @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@intCast(v))));
                return result;
            },

            .float => |v| {
                result.resolved_type = primitive_types.f64_;
                result.expr = @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralFloat64(v)));
                return result;
            },

            .symbol => |v| {
                // FIXME: use string interning
                if (v.ptr == syms.true.value.symbol.ptr) {
                    result.resolved_type = primitive_types.bool_;
                    result.expr = @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(1)));
                }

                if (v.ptr == syms.false.value.symbol.ptr) {
                    result.resolved_type = primitive_types.bool_;
                    result.expr = @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(0)));
                }

                if (context.label_map.get(v)) |label_data| {
                    return label_data.fragment;
                }

                const Info = struct {
                    resolved_type: Type,
                    ref: u32,
                };

                const info = _: {
                    if (context.locals.getPtr(v)) |local_entry| {
                        break :_ Info{
                            .resolved_type = local_entry.type,
                            .ref = local_entry.index,
                        };
                    }

                    // FIXME: use a map?
                    for (context.param_names, context.param_types, 0..) |pn, pt, i| {
                        // FIXME: this is ok because everything is a symbol, but should prob use a special type
                        if (pn.ptr == v.ptr) {
                            break :_ Info{
                                .resolved_type = pt,
                                .ref = @intCast(i),
                            };
                        }
                    }

                    std.log.err("undefined symbol2 '{s}'", .{v});
                    return error.UndefinedSymbol;
                };

                result.resolved_type = info.resolved_type;
                result.expr = @ptrCast(byn.c.BinaryenLocalGet(self.module.c(), info.ref, BinaryenHelper.getType(info.resolved_type)));

                return result;
            },

            .borrowedString, .ownedString => |v| {
                // FIXME: gross, require 0 terminated strings
                result.expr = byn.Expression.stringConst(self.module, try self.arena.allocator().dupeZ(u8, v)) catch unreachable;
                //result.frame_offset += @sizeOf(intrinsics.GrapplString);
                result.resolved_type = primitive_types.string;
                return result;
            },

            .bool => |v| {
                result.resolved_type = primitive_types.bool_;
                result.expr = @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(if (v) 1 else 0)));
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

        const UserFuncDef = struct {
            params: []Type,
            results: []Type,

            pub fn name(_self: @This(), a: std.mem.Allocator) ![:0]u8 {
                // NOTE: could use an arraylist writer with initial capacity
                var buf: [1024]u8 = undefined;
                var buf_writer = std.io.fixedBufferStream(&buf);
                _ = try buf_writer.write("callUserFunc_");
                for (_self.params) |param| {
                    _ = try buf_writer.write(param.name);
                    _ = try buf_writer.write("_");
                }
                _ = try buf_writer.write("R");
                for (_self.results) |result| {
                    _ = try buf_writer.write("_");
                    _ = try buf_writer.write(result.name);
                }

                return try a.dupeZ(u8, buf_writer.getWritten());
            }

            pub fn addImport(_self: @This(), ctx: *Compilation, in_name: [:0]const u8) !void {
                const param_types = try ctx.arena.allocator().alloc(byn.c.BinaryenType, _self.params.len + 1);
                defer ctx.arena.allocator().free(param_types); // FIXME: what is the binaryen ownership model
                for (_self.params, param_types[1..]) |graphl_t, *wasm_t| {
                    wasm_t.* = BinaryenHelper.getType(graphl_t);
                }
                const params: byn.c.BinaryenType = byn.c.BinaryenTypeCreate(param_types.ptr, @intCast(param_types.len));

                const result_types = try ctx.arena.allocator().alloc(byn.c.BinaryenType, _self.results.len);
                defer ctx.arena.allocator().free(result_types); // FIXME: what is the binaryen ownership model?
                for (_self.results, result_types) |graphl_t, *wasm_t| {
                    wasm_t.* = BinaryenHelper.getType(graphl_t);
                }
                const results: byn.c.BinaryenType = byn.c.BinaryenTypeCreate(result_types.ptr, @intCast(result_types.len));

                _ = byn.c.BinaryenAddFunctionImport(ctx.module.c(), in_name, "env", in_name, params, results);
            }
        };

        const UserFuncDefHashCtx = struct {
            pub fn hash(ctx: @This(), key: UserFuncDef) u64 {
                _ = ctx;
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHashStrat(&hasher, key, .Deep);
                return hasher.final();
            }

            pub fn eql(ctx: @This(), a: UserFuncDef, b: UserFuncDef) bool {
                _ = ctx;
                if (a.params.len != b.params.len) return false;
                if (a.results.len != b.results.len) return false;
                for (a.params, b.params) |pa, pb| if (pa != pb) return false;
                for (a.results, b.results) |ra, rb| if (ra != rb) return false;
                return true;
            }
        };

        var userfunc_imports: std.HashMapUnmanaged(UserFuncDef, [:0]const u8, UserFuncDefHashCtx, 80) = .{};

        // FIXME: fix stack
        // const stack_src =
        //     // NOTE: safari doesn't support multimemory so the value stack is
        //     // at a specific offset in the main memory
        //     //\\(memory $__grappl_vstk 1)
        //     // FIXME: really need to figure out how to customize the intrinsics output
        //     // compiled by zig... or accept writing it manually?
        //     // FIXME: if there is a lot of data, it will corrupt the stack,
        //     // need to place the stack behind the data and possibly implement a routine
        //     // for growing the stack...
        //     \\(global $__grappl_vstkp (mut i32) (i32.const 4096))
        // ;

        // // prologue
        // {
        //     const stack_code = try SexpParser.parse(alloc, stack_src, null);
        //     try self.module_body.appendSlice(stack_code.value.module.items);
        // }

        // // TODO: parse them at comptime and get the count that way
        // const stack_code_count = comptime std.mem.count(u8, stack_src, "\n") + 1;

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

        // NEXT: FIX THIS
        // // thunks for user provided functions
        {
            // TODO: for each user provided function, build a thunk and append it
            var next = self.user_context.funcs.first;
            while (next) |user_func| : (next = user_func.next) {
                const name = user_func.data.node.name;

                // FIXME: skip the first exec input
                std.debug.assert(user_func.data.node.inputs[0].kind.primitive == .exec);
                const params = user_func.data.node.inputs[1..];

                // FIXME: skip the first exec output
                std.debug.assert(user_func.data.node.outputs[0].kind.primitive == .exec);
                const results = user_func.data.node.outputs[1..];

                const def = UserFuncDef{
                    .params = try self.arena.allocator().alloc(Type, params.len),
                    .results = try self.arena.allocator().alloc(Type, results.len),
                };
                const byn_params = try self.arena.allocator().alloc(byn.c.BinaryenType, 1 + params.len);
                const byn_results = try self.arena.allocator().alloc(byn.c.BinaryenType, results.len);

                byn_params[0] = @intFromEnum(byn.Type.i32);
                for (params, def.params, byn_params[1..]) |param, *param_type, *byn_param| {
                    param_type.* = param.kind.primitive.value;
                    byn_param.* = BinaryenHelper.getType(param.kind.primitive.value);
                }
                for (results, def.results, byn_results) |result, *result_type, *byn_result| {
                    result_type.* = result.kind.primitive.value;
                    byn_result.* = BinaryenHelper.getType(result.kind.primitive.value);
                }

                var byn_args = try std.ArrayListUnmanaged(*byn.Expression).initCapacity(self.arena.allocator(), byn_params.len);
                defer byn_args.deinit(self.arena.allocator());
                byn_args.appendAssumeCapacity(@ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@intCast(user_func.data.id)))));
                byn_args.expandToCapacity();

                for (params, 0.., byn_args.items[1..]) |p, i, *byn_arg| {
                    byn_arg.* = byn.Expression.localGet(self.module, @intCast(i), @enumFromInt(BinaryenHelper.getType(p.kind.primitive.value)));
                }

                const import_entry = try userfunc_imports.getOrPut(self.arena.allocator(), def);

                const thunk_name = _: {
                    if (!import_entry.found_existing) {
                        import_entry.value_ptr.* = try def.name(self.arena.allocator());
                    }
                    break :_ import_entry.value_ptr.*;
                };

                const byn_param = byn.c.BinaryenTypeCreate(byn_params.ptr, @intCast(byn_params.len));
                const byn_result = byn.c.BinaryenTypeCreate(byn_results.ptr, @intCast(byn_results.len));

                const func = self.module.addFunction(
                    name,
                    @enumFromInt(byn_param),
                    @enumFromInt(byn_result),
                    &.{},
                    @ptrCast(byn.c.BinaryenCall(
                        self.module.c(),
                        thunk_name,
                        @ptrCast(byn_args.items.ptr),
                        @intCast(byn_args.items.len),
                        // FIXME: derive the result type
                        @intFromEnum(byn.Type.i32),
                    )),
                );

                _ = func;
            }
        }

        for (sexp.value.module.items) |decl| {
            switch (decl.value) {
                .list => {
                    // FIXME: maybe distinguish without errors if something if a func, var or typeof?
                    const did_compile = (try self.compileFunc(&decl) or
                        try self.compileVar(&decl) or
                        try self.compileTypeOf(&decl) or
                        try self.compileMeta(&decl) or
                        try self.compileImport(&decl));
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

        {
            var import_iter = userfunc_imports.iterator();
            while (import_iter.next()) |import_entry| {
                try import_entry.key_ptr.addImport(self, import_entry.value_ptr.*);
            }
        }

        // for (stack_code) |code| {
        //     _ = try code.write(buffer_writer, .{ .string_literal_dialect = .wat });
        //     try bytes.appendSlice("\n");
        // }

        // // FIXME: HACK: merge these properly...
        // try bytes.appendSlice(intrinsics_code);

        // for (module_defs) |def| {
        //     _ = try def.write(buffer_writer, .{ .string_literal_dialect = .wat });
        //     try bytes.appendSlice("\n");
        // }

        // FIXME: make the arena in this function not the caller
        // NOTE: use arena parent so that when the arena deinit's, this remains,
        // and the caller can own the memory
        const wasm_result = self.module.emitBinary("/script");
        defer byn.c.free(wasm_result.binary.ptr);
        // FIXME: return source map too
        defer byn.c.free(wasm_result.source_map.ptr);
        return try self.arena.child_allocator.dupe(u8, wasm_result.binary);
    }
};

pub fn compile(
    a: std.mem.Allocator,
    sexp: *const Sexp,
    user_funcs: ?*const std.SinglyLinkedList(UserFunc),
    _in_diagnostic: ?*Diagnostic,
) ![]const u8 {
    if (build_opts.disable_compiler) unreachable;
    var ignored_diagnostic: Diagnostic = undefined; // FIXME: why don't we init?
    const diag = if (_in_diagnostic) |d| d else &ignored_diagnostic;
    diag.root_sexp = sexp;

    var env = try Env.initDefault(a);
    defer env.deinit(a);

    var unit = try Compilation.init(a, &env, user_funcs, diag);
    defer unit.deinit();

    return unit.compileModule(sexp);
}

const t = std.testing;
const SexpParser = @import("./sexp_parser.zig").Parser;

pub const compiled_prelude = (
    \\;;; BEGIN INTRINSICS
    \\
++ intrinsics_code ++
    \\
    \\;;; END INTRINSICS
);

test "compile big" {
    // FIXME: support expression functions
    //     \\(define (++ x) (+ x 1))

    var user_funcs = std.SinglyLinkedList(UserFunc){};

    const user_func_1 = try t.allocator.create(std.SinglyLinkedList(UserFunc).Node);
    user_func_1.* = std.SinglyLinkedList(UserFunc).Node{
        .data = .{ .id = 0, .node = .{
            .name = "Confetti",
            .inputs = try t.allocator.dupe(Pin, &.{
                Pin{ .name = "exec", .kind = .{ .primitive = .exec } },
                Pin{
                    .name = "particleCount",
                    .kind = .{ .primitive = .{ .value = primitive_types.i32_ } },
                },
            }),
            .outputs = try t.allocator.dupe(Pin, &.{
                Pin{ .name = "", .kind = .{ .primitive = .exec } },
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
                .inputs = try t.allocator.dupe(Pin, &.{
                    Pin{ .name = "exec", .kind = .{ .primitive = .exec } },
                    Pin{
                        .name = "code",
                        .kind = .{ .primitive = .{ .value = primitive_types.code } },
                    },
                }),
                .outputs = try t.allocator.dupe(Pin, &.{
                    Pin{ .name = "", .kind = .{ .primitive = .exec } },
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
            _ = try env.addNode(t.allocator, graphl_builtin.basicMutableNode(&cursor.data.node));
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

    // imports could be in arbitrary order so just slice it off cuz length will
    // be the same
    const expected_prelude =
        \\(module
        \\(import "env"
        \\        "callUserFunc_code_R"
        \\        (func $callUserFunc_code_R
        \\              (param i32)
        \\              (param i32)))
        \\(import "env"
        \\        "callUserFunc_i32_R"
        \\        (func $callUserFunc_i32_R
        \\              (param i32)
        \\              (param i32)))
        \\(global $__grappl_vstkp
        \\        (mut i32)
        \\        (i32.const 4096))
        \\
    ++ compiled_prelude ++
        \\
        \\
    ;

    const expected =
        \\(func $sql
        \\      (param $param_0
        \\             i32)
        \\      (call $callUserFunc_code_R
        \\            (i32.const 1)
        \\            (local.get $param_0)))
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
        \\      (local $__frame_start
        \\             i32)
        \\      (local.set $__frame_start
        \\                 (global.get $__grappl_vstkp))
        \\      (call $sql
        \\            (i32.const 74)
        \\            (i32.const 8))
        \\      (call $sql
        \\            (i32.const 23)
        \\            (i32.const 124))
        \\      (local.set $local_a
        \\                 (i32.const 1))
        \\      (call $Confetti
        \\            (i32.const 100))
        \\      (call $__grappl_max
        \\            (local.get $param_x)
        \\            (local.get $local_a))
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\(data (i32.const 0)
        \\      "J\00\00\00{\22entry\22:[{\22symbol\22:\22-\22},{\22symbol\22:\22f\22},[{\22symbol\22:\22*\22},2,3]],\22labels\22:{}}")
        \\(data (i32.const 116)
        \\      "\17\00\00\00{\22entry\22:4,\22labels\22:{}}")
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
        \\      (local $__frame_start
        \\             i32)
        \\      (local.set $__frame_start
        \\                 (global.get $__grappl_vstkp))
        \\      (f32.add (f32.div (local.get $param_a)
        \\                        (f32.convert_i64_s (i64.extend_i32_s (i32.const 10))))
        \\               (f32.mul (local.get $param_a)
        \\                        (local.get $param_b)))
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\(export "ifs"
        \\        (func $ifs))
        \\(type $typeof_ifs
        \\      (func (param i32)
        \\            (result i32)))
        \\(func $ifs
        \\      (param $param_a
        \\             i32)
        \\      (result i32)
        \\      (local $__frame_start
        \\             i32)
        \\      (local.set $__frame_start
        \\                 (global.get $__grappl_vstkp))
        \\      (if (result i32)
        \\          (local.get $param_a)
        \\          (then (call $Confetti
        \\                      (i32.const 100))
        \\                (i32.add (i32.const 2)
        \\                         (i32.const 3)))
        \\          (else (call $Confetti
        \\                      (i32.const 200))
        \\                (i32.const 5)))
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\)
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &env, &user_funcs, &diagnostic)) |wat| {
        defer t.allocator.free(wat);
        {
            errdefer std.debug.print("======== prologue: =========\n{s}\n", .{wat[0 .. expected_prelude.len - compiled_prelude.len]});
            try t.expectEqualStrings(expected_prelude[0 .. expected_prelude.len - compiled_prelude.len], wat[0 .. expected_prelude.len - compiled_prelude.len]);
        }
        try t.expectEqualStrings(expected, wat[expected_prelude.len..]);
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}

test "new compiler" {
    // var env = try Env.initDefault(t.allocator);
    // defer env.deinit(t.allocator);

    var user_funcs = std.SinglyLinkedList(UserFunc){};

    const user_func_1 = try t.allocator.create(std.SinglyLinkedList(UserFunc).Node);
    user_func_1.* = std.SinglyLinkedList(UserFunc).Node{
        .data = .{ .id = 0, .node = .{
            .name = "Confetti",
            .inputs = try t.allocator.dupe(Pin, &.{
                Pin{ .name = "exec", .kind = .{ .primitive = .exec } },
                Pin{
                    .name = "particleCount",
                    .kind = .{ .primitive = .{ .value = primitive_types.i32_ } },
                },
            }),
            .outputs = try t.allocator.dupe(Pin, &.{
                Pin{ .name = "", .kind = .{ .primitive = .exec } },
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
                .inputs = try t.allocator.dupe(Pin, &.{
                    Pin{ .name = "exec", .kind = .{ .primitive = .exec } },
                    Pin{
                        .name = "code",
                        .kind = .{ .primitive = .{ .value = primitive_types.code } },
                    },
                }),
                .outputs = try t.allocator.dupe(Pin, &.{
                    Pin{ .name = "", .kind = .{ .primitive = .exec } },
                }),
            },
        },
    };
    defer t.allocator.destroy(user_func_2);
    defer t.allocator.free(user_func_2.data.node.inputs);
    defer t.allocator.free(user_func_2.data.node.outputs);
    user_funcs.prepend(user_func_2);

    var parsed = try SexpParser.parse(t.allocator,
        \\(meta version 1)
        \\(import Confetti "host/Confetti")
        \\(import sql "host/sql")
        \\
        \\;;; comment
        \\(typeof (++ i32) i32)
        \\(define (++ x)
        \\  (begin
        \\    (Confetti 100)
        \\    (return (+ x 1))))
        \\
        \\;;; comment
        \\(typeof (deep f32 f32) f32)
        \\(define (deep a b)
        \\  (begin
        \\    (return (+ (/ a 10) (* a b)))))
        \\
        \\;;; comment ;; TODO: reintroduce use of a parameter
        \\ ;;(typeof (ifs bool) i32)
        \\ ;;(define (ifs a)
        \\ ;;  (begin
        \\ ;;    (if a
        \\ ;;        (begin (Confetti 100)
        \\ ;;               (+ 2 3))
        \\ ;;        (begin (Confetti 200)
        \\ ;;               5))))
        \\
    , null);
    //std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit(t.allocator);

    // imports could be in arbitrary order so just slice it off cuz length will
    // be the same
    const expected_prelude =
        \\(module
        \\(import "env"
        \\        "callUserFunc_code_R"
        \\        (func $callUserFunc_code_R
        \\              (param i32)
        \\              (param i32)))
        \\(import "env"
        \\        "callUserFunc_i32_R"
        \\        (func $callUserFunc_i32_R
        \\              (param i32)
        \\              (param i32)))
        \\(global $__grappl_vstkp
        \\        (mut i32)
        \\        (i32.const 4096))
        \\
    ++ compiled_prelude ++
        \\
        \\
    ;
    _ = expected_prelude;

    const expected =
        \\(module
        \\  (type (;0;) (func (param i32) (result i32)))
        \\  (type (;1;) (func (param f32 f32) (result f32)))
        \\  (func (;0;) (type 0) (param i32) (result i32)
        \\    block (result i32)  ;; label = @1
        \\      local.get 0
        \\      i32.const 1
        \\      i32.add
        \\    end)
        \\  (func (;1;) (type 1) (param f32 f32) (result f32)
        \\    block (result f32)  ;; label = @1
        \\      local.get 0
        \\      i32.const 10
        \\      i64.extend_i32_s
        \\      f32.convert_i64_s
        \\      f32.div
        \\      local.get 0
        \\      local.get 1
        \\      f32.mul
        \\      f32.add
        \\    end)
        \\  (export "++" (func 0))
        \\  (export "deep" (func 1)))
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &user_funcs, &diagnostic)) |wasm| {
        defer t.allocator.free(wasm);
        try expectWasmEqualsWat(expected, wasm);
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}

pub fn expectWasmEqualsWat(wat: []const u8, wasm: []const u8) !void {
    // FIXME: convenience
    var tmp_dir = try std.fs.openDirAbsolute("/tmp", .{});
    defer tmp_dir.close();

    var dbg_file = try tmp_dir.createFile("compiler-test.wasm", .{});
    defer dbg_file.close();

    try dbg_file.writeAll(wasm);

    // TODO: use the wat2wasm dependency
    const wat2wasm_run = try std.process.Child.run(.{
        .allocator = t.allocator,
        .argv = &.{ "wasm2wat", "/tmp/compiler-test.wasm", "-o", "/tmp/compiler-test.wat" },
    });
    defer t.allocator.free(wat2wasm_run.stdout);
    defer t.allocator.free(wat2wasm_run.stderr);
    if (!std.meta.eql(wat2wasm_run.term, .{ .Exited = 0 })) {
        std.debug.print("wasm2wat exited with {any}:\n{s}\n", .{ wat2wasm_run.term, wat2wasm_run.stderr });
        return error.FailTest;
    }

    var dbg_wat_file = try tmp_dir.openFile("compiler-test.wat", .{});
    defer dbg_wat_file.close();
    var buff: [65536]u8 = undefined;
    const wat_data_size = try dbg_wat_file.readAll(&buff);

    const wat_data = buff[0..wat_data_size];

    return std.testing.expectEqualStrings(
        wat,
        wat_data,
    );
}

test "recurse" {
    // FIXME: support expression functions
    //     \\(define (++ x) (+ x 1))

    var env = try Env.initDefault(t.allocator);
    defer env.deinit(t.allocator);

    // FIXME: easier in the IDE to just pass the augmented env, but probably
    // better if the compiler can take a default env
    _ = try env.addNode(t.allocator, graphl_builtin.basicNode(&.{
        .name = "factorial",
        .inputs = &.{
            Pin{ .name = "in", .kind = .{ .primitive = .exec } },
            Pin{ .name = "n", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
        },
        .outputs = &.{
            Pin{ .name = "out", .kind = .{ .primitive = .exec } },
            Pin{ .name = "n", .kind = .{ .primitive = .{ .value = primitive_types.i32_ } } },
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
        \\(global $__grappl_vstkp
        \\        (mut i32)
        \\        (i32.const 4096))
        \\{s}
        \\(export "factorial"
        \\        (func $factorial))
        \\(type $typeof_factorial
        \\      (func (param i32)
        \\            (result i32)))
        \\(func $factorial
        \\      (param $param_n
        \\             i32)
        \\      (result i32)
        \\      (local $__frame_start
        \\             i32)
        \\      (local.set $__frame_start
        \\                 (global.get $__grappl_vstkp))
        \\      (if (result i32)
        \\          (i32.le_s (local.get $param_n)
        \\                    (i32.const 1))
        \\          (then (i32.const 1))
        \\          (else (i32.mul (local.get $param_n)
        \\                         (call $factorial
        \\                               (i32.sub (local.get $param_n)
        \\                                        (i32.const 1))))))
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\)
        // TODO: clearly instead of embedding the pointer we should have a global variable
        // so the host can set that
    , .{compiled_prelude});
    defer t.allocator.free(expected);

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &env, null, &diagnostic)) |wat| {
        defer t.allocator.free(wat);
        try t.expectEqualStrings(expected, wat);
        try expectWasmOutput(6, wat, "factorial", .{3});
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}

// TODO: better name
test "vec3 ref" {
    var env = try Env.initDefault(t.allocator);
    defer env.deinit(t.allocator);

    var user_funcs = std.SinglyLinkedList(UserFunc){};

    const user_func_1 = try t.allocator.create(std.SinglyLinkedList(UserFunc).Node);
    user_func_1.* = std.SinglyLinkedList(UserFunc).Node{
        .data = .{ .id = 0, .node = .{
            .name = "ModelCenter",
            .inputs = try t.allocator.dupe(Pin, &.{
                Pin{ .name = "", .kind = .{ .primitive = .exec } },
            }),
            .outputs = try t.allocator.dupe(Pin, &.{
                Pin{ .name = "", .kind = .{ .primitive = .exec } },
                Pin{ .name = "center", .kind = .{ .primitive = .{ .value = primitive_types.vec3 } } },
            }),
        } },
    };
    defer t.allocator.destroy(user_func_1);
    defer t.allocator.free(user_func_1.data.node.inputs);
    defer t.allocator.free(user_func_1.data.node.outputs);
    user_funcs.prepend(user_func_1);

    {
        var maybe_cursor = user_funcs.first;
        while (maybe_cursor) |cursor| : (maybe_cursor = cursor.next) {
            _ = try env.addNode(t.allocator, graphl_builtin.basicMutableNode(&cursor.data.node));
        }
    }

    var parsed = try SexpParser.parse(t.allocator,
        \\(typeof (processInstance u64
        \\                         vec3
        \\                         vec3)
        \\        string)
        \\(define (processInstance MeshId
        \\                         Origin
        \\                         Rotation)
        \\        (begin (ModelCenter) #!__label1
        \\               (if (> (Vec3->X __label1)
        \\                      2)
        \\                   (begin (return "my_export"))
        \\                   (begin (return "EXPORT2")))))
    , null);
    //std.debug.print("{any}\n", .{parsed});
    // FIXME: there is some double-free happening here?
    defer parsed.deinit(t.allocator);

    // imports could be in arbitrary order so just slice it off cuz length will
    // be the same
    const expected_prelude =
        \\(module
        \\(import "env"
        \\        "callUserFunc_R_vec3"
        \\        (func $callUserFunc_R_vec3
        \\              (param i32)
        \\              (result i32)))
        \\(global $__grappl_vstkp
        \\        (mut i32)
        \\        (i32.const 4096))
        \\
    ++ compiled_prelude ++
        \\
        \\
    ;

    const expected =
        \\(func $ModelCenter
        \\      (result i32)
        \\      (call $callUserFunc_R_vec3
        \\            (i32.const 0)))
        \\(export "processInstance"
        \\        (func $processInstance))
        \\(type $typeof_processInstance
        \\      (func (param i64)
        \\            (param i32)
        \\            (param i32)
        \\            (result i32)))
        \\(func $processInstance
        \\      (param $param_MeshId
        \\             i64)
        \\      (param $param_Origin
        \\             i32)
        \\      (param $param_Rotation
        \\             i32)
        \\      (result i32)
        \\      (local $__frame_start
        \\             i32)
        \\      (local $__lc0
        \\             i32)
        \\      (local $__lc1
        \\             i32)
        \\      (local $__lc2
        \\             i32)
        \\      (local.set $__frame_start
        \\                 (i32.add (global.get $__grappl_vstkp)
        \\                          (i32.const 8)))
        \\      (i32.store (global.get $__grappl_vstkp)
        \\                 (i32.const 9))
        \\      (i32.store (i32.add (global.get $__grappl_vstkp)
        \\                          (i32.const 4))
        \\                 (i32.const 4))
        \\      (local.set $__lc1
        \\                 (global.get $__grappl_vstkp))
        \\      (global.set $__grappl_vstkp
        \\                  (i32.add (global.get $__grappl_vstkp)
        \\                           (i32.const 8)))
        \\      (i32.store (global.get $__grappl_vstkp)
        \\                 (i32.const 7))
        \\      (i32.store (i32.add (global.get $__grappl_vstkp)
        \\                          (i32.const 4))
        \\                 (i32.const 25))
        \\      (local.set $__lc2
        \\                 (global.get $__grappl_vstkp))
        \\      (global.set $__grappl_vstkp
        \\                  (i32.add (global.get $__grappl_vstkp)
        \\                           (i32.const 8)))
        \\      (call $ModelCenter)
        \\      (local.set $__lc0)
        \\      (if (result i32)
        \\          (f64.gt (call $__grappl_vec3_x
        \\                        (local.get $__lc0))
        \\                  (f64.promote_f32 (f32.convert_i64_s (i64.extend_i32_s (i32.const 2)))))
        \\          (then (local.get $__lc1))
        \\          (else (local.get $__lc2)))
        \\      (global.set $__grappl_vstkp
        \\                  (local.get $__frame_start)))
        \\(data (i32.const 0)
        \\      "\09\00\00\00my_export")
        \\(data (i32.const 21)
        \\      "\07\00\00\00EXPORT2")
        \\)
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &env, &user_funcs, &diagnostic)) |wat| {
        defer t.allocator.free(wat);
        {
            errdefer std.debug.print("======== prologue: =========\n{s}\n", .{wat[0 .. expected_prelude.len - compiled_prelude.len]});
            try t.expectEqualStrings(expected_prelude[0 .. expected_prelude.len - compiled_prelude.len], wat[0 .. expected_prelude.len - compiled_prelude.len]);
        }
        try t.expectEqualStrings(expected, wat[expected_prelude.len..]);
        //try expectWasmOutput(6, wat, "processInstance", .{3});
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}

pub fn expectWasmOutput(
    comptime expected: anytype,
    wat: []const u8,
    entry: []const u8,
    comptime in_args: anytype,
) !void {
    // FIXME: convenience
    var tmp_dir = try std.fs.openDirAbsolute("/tmp", .{});
    defer tmp_dir.close();

    var dbg_file = try tmp_dir.createFile("compiler-test.wat", .{});
    defer dbg_file.close();

    try dbg_file.writeAll(wat);

    const wat2wasm_run = try std.process.Child.run(.{
        .allocator = t.allocator,
        .argv = &.{ "wat2wasm", "/tmp/compiler-test.wat", "-o", "/tmp/compiler-test.wasm" },
    });
    defer t.allocator.free(wat2wasm_run.stdout);
    defer t.allocator.free(wat2wasm_run.stderr);
    if (!std.meta.eql(wat2wasm_run.term, .{ .Exited = 0 })) {
        std.debug.print("wat2wasm exited with {any}:\n{s}\n", .{ wat2wasm_run.term, wat2wasm_run.stderr });
        return error.FailTest;
    }

    var dbg_wasm_file = try tmp_dir.openFile("compiler-test.wasm", .{});
    defer dbg_wasm_file.close();
    var buff: [65536]u8 = undefined;
    const wasm_data_size = try dbg_wasm_file.readAll(&buff);

    const wasm_data = buff[0..wasm_data_size];

    _ = wasm_data;

    _ = expected;
    _ = entry;
    _ = in_args;

    // const module_def = try bytebox.createModuleDefinition(t.allocator, .{});
    // defer module_def.destroy();

    // try module_def.decode(wasm_data);

    // const module_instance = try bytebox.createModuleInstance(.Stack, module_def, t.allocator);
    // defer module_instance.destroy();

    // const Local = struct {
    //     fn nullHostFunc(user_data: ?*anyopaque, _module: *bytebox.ModuleInstance, _params: [*]const bytebox.Val, _returns: [*]bytebox.Val) void {
    //         _ = user_data;
    //         _ = _module;
    //         _ = _params;
    //         _ = _returns;
    //     }
    // };

    // var imports = try bytebox.ModuleImportPackage.init("env", null, null, t.allocator);
    // defer imports.deinit();

    // inline for (&.{
    //     .{ "callUserFunc_code_R", &.{ .I32, .I32, .I32 }, &.{} },
    //     .{ "callUserFunc_code_R_string", &.{ .I32, .I32, .I32 }, &.{.I32} },
    //     .{ "callUserFunc_string_R", &.{ .I32, .I32, .I32 }, &.{} },
    //     .{ "callUserFunc_R", &.{.I32}, &.{} },
    //     .{ "callUserFunc_i32_R", &.{ .I32, .I32 }, &.{} },
    //     .{ "callUserFunc_i32_R_i32", &.{ .I32, .I32 }, &.{.I32} },
    //     .{ "callUserFunc_i32_i32_R_i32", &.{ .I32, .I32, .I32 }, &.{.I32} },
    //     .{ "callUserFunc_bool_R", &.{ .I32, .I32 }, &.{} },
    //     .{ "callUserFunc_u64_string_R_string", &.{ .I32, .I64, .I32, .I32 }, &.{.I32} },
    // }) |import_desc| {
    //     const name, const params, const results = import_desc;
    //     try imports.addHostFunction(name, params, results, Local.nullHostFunc, null);
    // }

    // try module_instance.instantiate(.{
    //     .imports = &.{imports},
    // });

    // const handle = try module_instance.getFunctionHandle(entry);

    // comptime var args: [in_args.len]bytebox.Val = undefined;
    // inline for (in_args, &args) |in_arg, *arg| {
    //     arg.* = bytebox.Val{ .I32 = in_arg };
    // }
    // const ready_args = args;

    // var results = [_]bytebox.Val{bytebox.Val{ .I32 = 0 }};
    // results[0] = bytebox.Val{ .I32 = 0 }; // FIXME:
    // try module_instance.invoke(handle, &ready_args, &results, .{});

    // switch (@typeInfo(@TypeOf(expected))) {
    //     .Array, .Pointer => {
    //         const GrapplString = intrinsics.GrapplString;
    //         const ptr: usize = @intCast(results[0].I32);
    //         comptime std.debug.assert(builtin.cpu.arch.endian() == .little);
    //         // FIXME: really I should be aligning things, even if wasm doesn't require it, I'm sure it provides
    //         // better performance
    //         const str_wasm_mem: *align(1) GrapplString = std.mem.bytesAsValue(GrapplString, module_instance.memoryAll()[ptr .. ptr + @sizeOf(GrapplString)]);

    //         // var dump = try std.fs.createFileAbsolute("/tmp/test-dump.wasmmem", .{});
    //         // defer dump.close();
    //         // try dump.writeAll(module_instance.memoryAll());

    //         const str = module_instance.memoryAll()[str_wasm_mem.ptr .. str_wasm_mem.ptr + str_wasm_mem.len];
    //         try std.testing.expectEqualStrings(expected, str);
    //     },
    //     .ComptimeInt, .Int => try std.testing.expectEqual(expected, results[0].I32),
    //     else => @compileError("unsupported type for wasm tests: " ++ @typeName(@TypeOf(expected))),
    // }
}

test {
    // TODO: move to compiler/tests directory
    t.refAllDecls(@import("./compiler-tests-string.zig"));
    t.refAllDecls(@import("./compiler-tests-types.zig"));
}

const bytebox = @import("bytebox");
const byn = @import("binaryen");
