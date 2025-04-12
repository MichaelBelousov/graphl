//! TODO: move this to another place
//! ABI:
//! - stack
//! - For functions:
//!   - Each graphl parameter function is converted to a wasm parameter
//!     - primitives are passed by value
//!     - compound types are passed by reference
//!   - an i32 parameter is added storing the return address
//!     - in the future we can return primitive types directly
//!   - Every node that has value outputs is given a stack slot holding
//!     its value
//!   - executing a function involves pushing its frame on to the stack and
//!     calling it with the caller's slot as the return address
//!
//! // FIXME: rewrite this
//! HIGH LEVEL OVERVIEW
//!

const builtin = @import("builtin");
const build_opts = @import("build_opts");
const std = @import("std");
const json = std.json;
const Sexp = @import("./sexp.zig").Sexp;
const Loc = @import("./loc.zig").Loc;
const ModuleContext = @import("./sexp.zig").ModuleContext;
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
const SymMapUnmanaged = @import("./InternPool.zig").SymMapUnmanaged;

const t = std.testing;
const SexpParser = @import("./sexp_parser.zig").Parser;
const SpacePrint = @import("./sexp_parser.zig").SpacePrint;

const log = std.log.scoped(.graphlt_compiler);

const intrinsics_vec3 = @embedFile("graphl_intrinsics_vec3");

pub const Diagnostic = struct {
    err: Error = .None,

    // set upon start of compilation
    /// the sexp parsed from the source contextually related to the stored error
    graphlt_module: *const ModuleContext = undefined,

    const Error = union(enum(u16)) {
        None = 0,
        BadTopLevelForm: u32,
        UndefinedSymbol: u32,
        DuplicateVariable: u32,
        DuplicateParam: u32,
        EmptyCall: u32,
        NonSymbolCallee: u32,
        UnimplementedMultiResultHostFunc: u32,
        UnhandledCall: u32,
        DuplicateLabel: u32,
        // FIXME: add the dependency to the error message
        RecursiveDependency: u32,
        SetNonSymbol: u32,
        BuiltinWrongArity: struct {
            callee: u32,
            expected: u16,
            received: u16,
        },
        DefineWithoutTypeOf: u32,
        InvalidIR,
    };

    const Code = error{
        BadTopLevelForm,
        UndefinedSymbol,
        DuplicateVariable,
        DuplicateParam,
        EmptyCall,
        NonSymbolCallee,
        UnimplementedMultiResultHostFunc,
        UnhandledCall,
        DuplicateLabel,
        RecursiveDependency,
        SetNonSymbol,
        BuiltinWrongArity,
        DefineWithoutTypeOf,
        InvalidIR,
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
            .BadTopLevelForm => |idx| {
                try writer.print("bad top level form:\n{}\n", .{Sexp.withContext(self.graphlt_module, idx)});
            },
            // TODO: add a contextualize function?
            .UndefinedSymbol => |sym_id| {
                // FIXME: HACK
                const sexp = self.graphlt_module.get(sym_id);

                std.debug.assert(sexp.span != null and self.graphlt_module.source != null);

                const span = sexp.span.?;
                const byte_offset: usize = span.ptr - self.graphlt_module.source.?.ptr;

                var loc: Loc = .{};
                while (loc.index != byte_offset) {
                    loc.increment(self.graphlt_module.source.?);
                }

                try writer.print(
                    \\Undefined symbol '{s}' in {}:
                    \\  | {s}
                    \\    {}^
                    \\
                , .{
                    sexp.value.symbol,
                    loc,
                    try loc.containing_line(self.graphlt_module.source.?),
                    SpacePrint.init(loc.col - 1),
                });
            },
            .BuiltinWrongArity => |err_info| {
                // FIXME: HACK
                const sexp = self.graphlt_module.get(err_info.callee);

                std.debug.assert(sexp.span != null and self.graphlt_module.source != null);

                const span = sexp.span.?;
                const byte_offset: usize = span.ptr - self.graphlt_module.source.?.ptr;

                var loc: Loc = .{};
                while (loc.index != byte_offset) {
                    loc.increment(self.graphlt_module.source.?);
                }

                try writer.print(
                    \\Incorrect argument count for '{s}' in {}:
                    \\  | {s}
                    \\    {}^
                    \\Expected {} arguments but received {}.
                    \\
                , .{
                    sexp.value.symbol,
                    loc,
                    try loc.containing_line(self.graphlt_module.source.?),
                    SpacePrint.init(loc.col - 1),
                    err_info.expected,
                    err_info.received,
                });
            },
            .InvalidIR => {
                try writer.writeAll(
                    \\Compiler failed to generate valid binaryen IR, see stderr for details.
                    \\
                );
            },
            inline else => |idx, tag| {
                // FIXME: HACK
                const sexp = self.graphlt_module.get(idx);

                std.debug.assert(sexp.span != null and self.graphlt_module.source != null);
                const span = sexp.span.?;
                const byte_offset: usize = span.ptr - self.graphlt_module.source.?.ptr;

                var loc: Loc = .{};
                while (loc.index != byte_offset) {
                    loc.increment(self.graphlt_module.source.?);
                }

                try writer.print(
                    \\{s}: '{s}' in {}:
                    \\  | {s}
                    \\    {}^
                    \\
                , .{
                    @tagName(tag),
                    sexp.value.symbol,
                    loc,
                    try loc.containing_line(self.graphlt_module.source.?),
                    SpacePrint.init(loc.col - 1),
                });
            },
        }
    }
};

const DeferredFuncDeclInfo = struct {
    param_name_idxs: []const u32,
    param_names: []const [:0]const u8,
    /// indices into the graphlt module context
    local_name_idxs: []const u32,
    local_names: []const [:0]const u8,
    local_types: []const Type,
    /// indices into the graphlt module context, if there was a default
    local_defaults: []const ?u32,
    result_names: []const [:0]const u8,
    define_body_idx: u32,
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

const Features = struct {
    vec3: bool = false,
    string: bool = false,
};

const BinaryenHelper = struct {
    var alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var type_map: std.AutoHashMapUnmanaged(Type, byn.c.BinaryenType) = .{};

    pub fn getType(graphl_type: Type, features: *Features) byn.c.BinaryenType {
        // TODO: use switch if compiler supports it
        if (graphl_type == primitive_types.string) {
            features.string = true;
        } else if (graphl_type == primitive_types.vec3) {
            features.vec3 = true;
        }

        return type_map.get(graphl_type) orelse {
            std.debug.panic("No binaryen type registered for graphl type '{s}'", .{graphl_type.name});
        };
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
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.char_, byn.c.BinaryenTypeInt32()) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.void, byn.c.BinaryenTypeNone()) catch unreachable;

    // TODO: do the same thing as guile hoot, use the stringref proposal but lower it to (array i8)
    const tb: byn.c.TypeBuilderRef = byn.c.TypeBuilderCreate(2);
    //byn.c.TypeBuilderSetArrayType(tb, 0, byn.c.BinaryenTypeInt32(), byn.c.BinaryenPackedTypeInt8(), 1);
    byn.c.TypeBuilderSetArrayType(tb, 0, byn.c.BinaryenTypeInt32(), byn.c.BinaryenPackedTypeInt8(), 1);

    var vec3_parts = .{
        .types = [_]byn.c.BinaryenType{
            byn.c.BinaryenTypeFloat64(),
            byn.c.BinaryenTypeFloat64(),
            byn.c.BinaryenTypeFloat64(),
        },
        .@"packed" = [_]byn.c.BinaryenPackedType{
            byn.c.BinaryenPackedTypeNotPacked(),
            byn.c.BinaryenPackedTypeNotPacked(),
            byn.c.BinaryenPackedTypeNotPacked(),
        },
        .mut = BinaryenHelper.alloc.allocator().dupe(bool, &[_]bool{
            true,
            true,
            true,
        }) catch unreachable,
    };

    // FIXME: lazily add this type if a string is used!
    byn.c.TypeBuilderSetStructType(
        tb,
        1,
        &vec3_parts.types,
        &vec3_parts.@"packed",
        vec3_parts.mut.ptr,
        3,
    );

    var built_heap_types: [2]byn.c.BinaryenHeapType = undefined;
    std.debug.assert(byn.c.TypeBuilderBuildAndDispose(tb, &built_heap_types, 0, 0));
    const i8_array = byn.c.BinaryenTypeFromHeapType(built_heap_types[0], true);
    const vec3 = byn.c.BinaryenTypeFromHeapType(built_heap_types[1], true);

    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.vec3, vec3) catch unreachable;

    // NOTE: stringref isn't standard
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.code, i8_array) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.symbol, i8_array) catch unreachable;
    // FIXME: lazily add this type if a string is used!
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.string, i8_array) catch unreachable;
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

    graphlt_module: *const ModuleContext,
    // NOTE: this coul
    _sexp_compiled: []Slot,

    // FIXME: figure out how this works cuz rn I'm not sure I'm even using this at all in the memory, using
    // segments instead, but I need to read more
    // according to binaryen docs, there are optimizations if you
    // do not use the first 1Kb
    ro_data_offset: u32 = 1024,

    module: *byn.Module,
    arena: std.heap.ArenaAllocator,
    user_context: struct {
        funcs: *const std.SinglyLinkedList(UserFunc),
        func_map: std.StringHashMapUnmanaged(*UserFunc),
    },

    used_features: Features = .{},

    // FIXME: support multiple diagnostics
    diag: *Diagnostic,

    pub const Slot = struct {
        // FIXME: should this have a pointer to its frame?
        /// how far into its frame the data for this item starts (if it is a primitive)
        frame_depth: u32,
        /// index of the local holding this data in its function
        local_index: byn.c.BinaryenIndex,
        /// if empty_type, then not yet resolved
        type: Type = graphl_builtin.empty_type,

        /// the block of code to jump to to execute dependencies and then this slot's code
        pre_block: byn.c.RelooperBlockRef,
        /// the block of code after dependencies
        post_block: byn.c.RelooperBlockRef,

        // TODO: try to avoid having two blocks/exprs
        /// the expression to execute after evaluating dependencies
        expr: byn.c.BinaryenExpressionRef,
    };

    pub const main_mem_name = "0";

    pub fn init(
        alloc: std.mem.Allocator,
        graphlt_module: *const ModuleContext,
        env: *Env,
        maybe_user_funcs: ?*const std.SinglyLinkedList(UserFunc),
        in_diag: *Diagnostic,
    ) !@This() {
        var result = @This(){
            .graphlt_module = graphlt_module,
            ._sexp_compiled = undefined,
            .diag = in_diag,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .env = env,
            .module = byn.Module.init(),
            .user_context = .{
                .funcs = maybe_user_funcs orelse &empty_user_funcs,
                .func_map = undefined,
            },
        };

        byn.c.BinaryenSetDebugInfo(true);

        result._sexp_compiled = try result.arena.allocator().alloc(Slot, graphlt_module.arena.items.len);

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
                byn.Features.BulkMemory(),
            }),
        );

        // const segmentNames = [_][]const u8{ "0", "1" };
        // const segmentDatas = [_][]const u8{ "empty", "empty" };
        // const segmentPassives = [_]bool{ false, true };
        // const segmentOffsets = [_]byn.c.BinaryenExpressionRef{
        //     byn.c.BinaryenConst(result.module.c(), byn.c.BinaryenLiteralInt32(10)),
        //     null,
        // };
        // const segmentSizes = [_]byn.c.BinaryenIndex{ 12, 12 };

        byn.c.BinaryenSetMemory(
            result.module.c(),
            // FIXME: this actually depends upon the amount of strings,
            // so set memory at the end of compilation
            1,
            256,
            "memory", // exportName (causes export unless null)
            null, // segmentNames // NOTE: I think these are for multimemory support
            null, // segmentDatas
            null, // segmentPassives
            null, // segmentOffsets
            null, // segmentSizes
            0, // numSegments
            false, // shared
            false, // memory64
            main_mem_name, // name
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
        self.arena.allocator().free(self._sexp_compiled);
        self.arena.deinit();
    }

    fn compileFunc(self: *@This(), sexp_index: u32) !bool {
        const alloc = self.arena.allocator();
        const sexp: *const Sexp = self.graphlt_module.get(sexp_index);

        if (Sexp.findPatternMismatch(self.graphlt_module, sexp_index,
            \\(define (SYMBOL ...SYMBOL) ...ANY)
        )) |mismatch| {
            _ = mismatch;
            return false;
        }

        const body_expr_idxs = sexp.value.list.items[2..];

        // FIXME: use unmanaged array list? there are a lot of these...
        var local_names = std.ArrayList([:0]const u8).init(alloc);
        defer local_names.deinit();

        var local_name_idxs = std.ArrayList(u32).init(alloc);
        defer local_name_idxs.deinit();

        var local_types = std.ArrayList(Type).init(alloc);
        defer local_types.deinit();

        var local_defaults = std.ArrayList(?u32).init(alloc);
        defer local_defaults.deinit();

        for (body_expr_idxs) |maybe_local_def_idx| {
            const maybe_local_def = self.graphlt_module.get(maybe_local_def_idx);
            // if (maybe_local_def.value != .list) break;
            // if (maybe_local_def.value.list.items.len < 3) break;
            // if (maybe_local_def.value.list.items[0].value.symbol.ptr != syms.define.value.symbol.ptr and maybe_local_def.value.list.items[0].value.symbol.ptr != syms.typeof.value.symbol.ptr)
            //     break;
            // if (maybe_local_def.value.list.items[1].value != .symbol) return error.LocalBindingNotSymbol;

            const is_def = Sexp.findPatternMismatch(self.graphlt_module, maybe_local_def_idx, "(define SYMBOL ...ANY)") == null;
            const is_typeof = Sexp.findPatternMismatch(self.graphlt_module, maybe_local_def_idx, "(typeof SYMBOL ...ANY)") == null;
            // locals are all in one block at the beginning. If it's not a local def, stop looking for more
            if (!is_def and !is_typeof) break;

            const local_name = maybe_local_def.getWithModule(1, self.graphlt_module).value.symbol;

            if (is_typeof) {
                const local_type = maybe_local_def.getWithModule(2, self.graphlt_module);
                if (local_type.value != .symbol)
                    return error.LocalBindingTypeNotSymbol;
                // TODO: diagnostic
                try local_types.append(self.env.getType(local_type.value.symbol) orelse return error.TypeNotFound);
            } else {
                const local_default = _: {
                    if (maybe_local_def.value.list.items.len >= 3) {
                        break :_ maybe_local_def.value.list.items[2];
                    } else {
                        break :_ null;
                    }
                };
                try local_defaults.append(local_default);
                try local_names.append(local_name);
                try local_name_idxs.append(maybe_local_def.value.list.items[1]);
            }
        }

        const func_name = sexp.getWithModule(1, self.graphlt_module).getWithModule(0, self.graphlt_module).value.symbol;
        //const params = sexp.value.list.items[1].value.list.items[1..];
        const func_name_mangled = func_name;
        _ = func_name_mangled;

        const func_bindings_idxs = sexp.getWithModule(1, self.graphlt_module).value.list.items[1..];

        const param_names = try alloc.alloc([:0]const u8, func_bindings_idxs.len);
        errdefer alloc.free(param_names);

        const param_name_idxs = try alloc.alloc(u32, func_bindings_idxs.len);
        errdefer alloc.free(param_name_idxs);

        for (func_bindings_idxs, param_names, param_name_idxs) |func_binding_idx, *param_name, *param_idx| {
            const func_binding = self.graphlt_module.get(func_binding_idx);
            param_name.* = func_binding.value.symbol;
            param_idx.* = func_binding_idx;
        }

        const func_desc = DeferredFuncDeclInfo{
            .param_names = param_names,
            .param_name_idxs = param_name_idxs,
            // TODO: read all defines at beginning of sexp or something
            .local_names = try local_names.toOwnedSlice(),
            .local_name_idxs = try local_name_idxs.toOwnedSlice(),
            .local_types = try local_types.toOwnedSlice(),
            .local_defaults = try local_defaults.toOwnedSlice(),
            .result_names = &.{}, // FIXME
            .define_body_idx = sexp_index,
        };

        if (self.deferred.func_types.get(func_name)) |func_type| {
            try self.finishCompileTypedFunc(func_name, func_desc, func_type);
        } else {
            try self.deferred.func_decls.put(alloc, func_name, func_desc);
        }

        return true;
    }

    fn compileMeta(self: *@This(), sexp_index: u32) !bool {
        if (Sexp.findPatternMismatch(self.graphlt_module, sexp_index,
            \\(meta version 1)
        )) |_| {
            return false;
        }

        const sexp = self.graphlt_module.get(sexp_index);

        if (sexp.getWithModule(2, self.graphlt_module).value.int != 1) return error.UnsupportedVersion;

        return true;
    }

    fn compileImport(self: *@This(), sexp: *const Sexp) !bool {
        if (sexp.value != .list) return false;
        if (sexp.value.list.items.len == 0) return false;
        if (sexp.getWithModule(0, self.graphlt_module).value != .symbol) return error.NonSymbolHead;
        if (sexp.getWithModule(0, self.graphlt_module).value.symbol.ptr != syms.import.value.symbol.ptr) return false;
        if (sexp.getWithModule(1, self.graphlt_module).value != .symbol) return error.NonSymbolBinding;
        if (sexp.getWithModule(2, self.graphlt_module).value != .ownedString) return error.NonStringPackagePath;

        const import_binding = sexp.getWithModule(1, self.graphlt_module).value.symbol;

        const imported = try self.analyzeImportAtPath(sexp.getWithModule(2, self.graphlt_module).value.ownedString);

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

    fn compileVar(self: *@This(), sexp_index: u32) !bool {
        const sexp = self.graphlt_module.get(sexp_index);

        if (Sexp.findPatternMismatch(self.graphlt_module, sexp_index,
            \\(define SYMBOL ...ANY)
        )) |_| return false;

        const var_name = sexp.getWithModule(1, self.graphlt_module).value.symbol;
        //const params = sexp.value.list.items[1].value.list.items[1..];
        const var_name_mangled = var_name;
        _ = var_name_mangled;

        //byn.Expression;

        return true;
    }

    fn compileTypeOf(self: *@This(), sexp_index: u32) !bool {
        const sexp = self.graphlt_module.get(sexp_index);

        const is_typeof_var = Sexp.findPatternMismatch(self.graphlt_module, sexp_index,
            \\(typeof SYMBOL ...ANY)
        ) == null;

        const is_typeof_func = Sexp.findPatternMismatch(self.graphlt_module, sexp_index,
            \\(typeof (SYMBOL ...SYMBOL) ...ANY)
        ) == null;

        if (is_typeof_var) {
            return self.compileTypeOfVar(sexp);
        } else if (is_typeof_func) {
            return self.compileTypeOfFunc(sexp);
        } else {
            return false;
        }
    }

    /// e.g. (typeof (f i32) i32)
    fn compileTypeOfFunc(self: *@This(), sexp: *const Sexp) !bool {
        const alloc = self.arena.allocator();

        // std.debug.assert(sexp.value == .list);
        // std.debug.assert(sexp.value.list.items[0].value == .symbol);
        // // FIXME: parser should be aware of the define form!
        // //std.debug.assert(sexp.value.list.items[0].value.symbol.ptr == syms.typeof.value.symbol.ptr);
        // std.debug.assert(std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.typeof.value.symbol));

        // if (sexp.value.list.items[1].value != .list) return false;
        // if (sexp.value.list.items[1].value.list.items.len == 0) return error.FuncTypeDeclListEmpty;
        // for (sexp.value.list.items[1].value.list.items) |*def_item| {
        //     // FIXME: function types names must be simple symbols (for now)
        //     if (def_item.value != .symbol) return error.FuncBindingsListEmpty;
        // }

        const func_name = sexp.getWithModule(1, self.graphlt_module).getWithModule(0, self.graphlt_module).value.symbol;
        const param_type_expr_idxs = sexp.getWithModule(1, self.graphlt_module).value.list.items[1..];

        // FIXME: types must be symbols (for now)
        if (sexp.getWithModule(2, self.graphlt_module).value != .symbol) return error.FuncTypeDeclResultNotASymbol;

        const result_type_name = sexp.getWithModule(2, self.graphlt_module).value.symbol;

        const param_types = try alloc.alloc(Type, param_type_expr_idxs.len);
        errdefer alloc.free(param_types);
        for (param_type_expr_idxs, param_types) |type_expr_idx, *type_| {
            const type_expr = self.graphlt_module.get(type_expr_idx);
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

        // FIXME: remove this allocator it's very unobvious when rereading code
        const alloc = self.arena.allocator();

        const complete_func_type_desc = graphl_builtin.FuncType{
            .param_names = func_decl.param_names,
            .param_types = func_type.param_types,
            .local_names = func_decl.local_names,
            .local_types = func_decl.local_types,
            .result_names = func_decl.result_names,
            .result_types = func_type.result_types,
        };

        const param_types = try self.arena.allocator().alloc(byn.c.BinaryenType, complete_func_type_desc.param_types.len);
        defer self.arena.allocator().free(param_types); // FIXME: what is the binaryen ownership model
        for (param_types, complete_func_type_desc.param_types) |*wasm_t, graphl_t| {
            wasm_t.* = BinaryenHelper.getType(graphl_t, &self.used_features);
        }
        const param_type_byn: byn.c.BinaryenType = byn.c.BinaryenTypeCreate(param_types.ptr, @intCast(param_types.len));

        const result_types = try self.arena.allocator().alloc(byn.c.BinaryenType, complete_func_type_desc.result_types.len);
        defer self.arena.allocator().free(result_types); // FIXME: what is the binaryen ownership model?
        for (result_types, complete_func_type_desc.result_types) |*wasm_t, graphl_t| {
            wasm_t.* = BinaryenHelper.getType(graphl_t, &self.used_features);
        }

        const ResultType = struct {
            byn: byn.c.BinaryenType,
            graphl: Type,
        };

        // FIXME: don't make a tuple type if there's only 1!
        const result_type: ResultType = _: {
            if (func_type.result_types.len == 1) {
                break :_ .{
                    .byn = BinaryenHelper.getType(func_type.result_types[0], &self.used_features),
                    .graphl = func_type.result_types[0],
                };
            } else {
                // FIXME: separate function and whole module arenas
                const graphl_type_slot = try self.arena.allocator().create(TypeInfo);
                graphl_type_slot.* = .{
                    .name = name,
                    .size = 0,
                    .subtype = .{ .@"struct" = .{
                        .field_types = func_type.result_types,
                        .field_names = func_decl.result_names,
                    } },
                };
                break :_ .{
                    .byn = byn.c.BinaryenTypeCreate(result_types.ptr, @intCast(result_types.len)),
                    .graphl = graphl_type_slot,
                };
            }
        };

        // now that we have func
        {
            const node_desc = try self.arena.allocator().create(graphl_builtin.BasicMutNodeDesc);
            node_desc.* = .{
                .name = name,
                .kind = .func,
                // FIXME: can I reuse pins?
                .inputs = try self.arena.allocator().alloc(Pin, func_type.param_types.len + 1),
                .outputs = try self.arena.allocator().alloc(Pin, func_type.result_types.len + 1),
            };
            node_desc.inputs[0] = Pin{ .name = "in", .kind = .{ .primitive = .exec } };
            for (node_desc.inputs[1..], func_decl.param_names, func_type.param_types) |*pin, pn, pt| {
                pin.* = Pin{ .name = pn, .kind = .{ .primitive = .{ .value = pt } } };
            }
            node_desc.outputs[0] = Pin{ .name = "out", .kind = .{ .primitive = .exec } };
            for (node_desc.outputs[1..], func_type.result_types) |*pin, rt| {
                pin.* = Pin{ .name = "FIXME", .kind = .{ .primitive = .{ .value = rt } } };
            }
            // we must use the same allocator that env is deinited with!
            _ = try self.env.addNode(self.arena.child_allocator, graphl_builtin.basicMutableNode(node_desc));
        }

        // FIXME: rename
        // TODO: use @FieldType

        var locals_symbols: SymMapUnmanaged(FnContext.LocalInfo) = .{};
        defer locals_symbols.deinit(self.arena.allocator());

        for (func_decl.param_names, func_decl.param_name_idxs, func_type.param_types) |p_name, p_idx, p_type| {
            const index: u32 = @intCast(locals_symbols.count());
            const put_res = try locals_symbols.getOrPut(alloc, p_name);

            if (put_res.found_existing) {
                self.diag.err = .{ .DuplicateParam = p_idx };
                return error.DuplicateParam;
            }

            put_res.value_ptr.* = .{
                .index = index,
                .type = p_type,
            };

            // FIXME: why not add this to the env as a getter?
        }

        var byn_locals_types: std.ArrayListUnmanaged(Type) = .{};
        defer byn_locals_types.deinit(self.arena.allocator());

        var fn_ctx = FnContext{
            .local_symbols = &locals_symbols,
            .local_types = &byn_locals_types,
            // locals should be placed after params
            .param_count = @intCast(func_type.param_types.len),
            .next_sexp_local_idx = @intCast(func_type.param_types.len),
            .relooper = byn.c.RelooperCreate(self.module.c()) orelse @panic("relooper creation failed"),
            .return_type = result_type.graphl,
        };

        try self.compileExpr(func_decl.define_body_idx, &fn_ctx, ExprContext{ .type = result_type.graphl });
        try self.linkExpr(
            func_decl.define_body_idx,
            &fn_ctx,
            byn.c.RelooperAddBlock(fn_ctx.relooper, byn.c.BinaryenNop(self.module.c())),
        );

        const body_slot = &self._sexp_compiled[func_decl.define_body_idx];

        // FIXME: use a compound result type to avoid this check
        std.debug.assert(func_type.result_types.len == 1);
        if (body_slot.type != func_type.result_types[0]) {
            //std.log.warn("body_fragment:\n{}\n", .{Sexp{ .value = .{ .module = expr_fragment.values } }});
            log.warn("type: '{s}' doesn't match '{s}'", .{ body_slot.type.name, func_type.result_types[0].name });
            // FIXME/HACK: re-enable but disabling now to awkwardly allow for type promotion
            //return error.ReturnTypeMismatch;
        }

        // const is_compound_result_type: bool = _: {
        //     // TODO: support user compound types
        //     if (body_res.type != graphl_builtin.empty_type) {
        //         inline for (comptime std.meta.declarations(graphl_builtin.compound_builtin_types)) |decl| {
        //             const type_ = @field(graphl_builtin.compound_builtin_types, decl.name);
        //             if (type_ == body_res.type)
        //                 break :_ true;
        //         }
        //         break :_ false;
        //     } else {
        //         // FIXME: empty body is just void, not an error
        //         return error.ResultTypeNotDetermined;
        //     }
        // };

        const entry = self._sexp_compiled[func_decl.define_body_idx].pre_block;
        const body = byn.c.RelooperRenderAndDispose(
            fn_ctx.relooper,
            entry,
            0, // FIXME: figure out label
        );

        const byn_local_types = try self.arena.allocator().alloc(byn.Type, byn_locals_types.items.len);
        defer self.arena.allocator().free(byn_local_types);
        for (byn_local_types, byn_locals_types.items) |*byn_local_type, local_type| {
            byn_local_type.* =
                // FIXME: don't store locals for empties
                if (local_type == graphl_builtin.empty_type)
                    byn.Type.i32
                else
                    @enumFromInt(BinaryenHelper.getType(local_type, &self.used_features));
        }

        std.debug.print("result type: {s}\n", .{result_type.graphl.name});
        const func = self.module.addFunction(
            name,
            @enumFromInt(param_type_byn),
            @enumFromInt(result_type.byn),
            byn_local_types,
            @ptrCast(body),
        );

        std.debug.assert(func != null);

        const export_ref = byn.c.BinaryenAddFunctionExport(self.module.c(), name, name);
        std.debug.assert(export_ref != null);
    }

    fn compileExpr(
        self: *@This(),
        code_sexp_idx: u32,
        /// not const because we may be expanding the frame to include this value
        fn_ctx: *FnContext,
        expr_ctx: ExprContext,
    ) CompileExprError!void {
        const code_sexp = self.graphlt_module.get(code_sexp_idx);
        const slot = &self._sexp_compiled[code_sexp_idx];
        slot.expr = undefined;

        const local_index = fn_ctx.putLocalForSexp(self, code_sexp_idx);

        done: {
            switch (code_sexp.value) {
                .list => |v| {
                    if (v.items.len == 0) {
                        self.diag.err = .{ .EmptyCall = code_sexp_idx };
                        return error.EmptyCall;
                    }

                    const func = self.graphlt_module.get(v.items[0]);

                    if (func.value != .symbol) {
                        self.diag.err = .{ .NonSymbolCallee = code_sexp_idx };
                        return error.NonSymbolCallee;
                    }

                    if (func.value.symbol.ptr == syms.typeof.value.symbol.ptr) {
                        slot.type = graphl_builtin.empty_type;
                        slot.expr = byn.c.BinaryenNop(self.module.c());

                        if (v.items.len != 3) {
                            self.diag.err = .{ .BuiltinWrongArity = .{
                                .callee = v.items[0],
                                .expected = 2,
                                .received = @intCast(v.items.len - 1),
                            } };
                            return error.BuiltinWrongArity; // FIXME: add diag
                        }

                        const binding = self.graphlt_module.get(v.items[1]);
                        if (binding.value != .symbol) {
                            // FIXME: wrong code
                            self.diag.err = .{ .NonSymbolCallee = v.items[1] };
                            return error.NonSymbolCallee;
                        }
                        const sym = binding.value.symbol;

                        const value_sexp = self.graphlt_module.get(v.items[2]);
                        if (binding.value != .symbol) {
                            // FIXME: wrong code
                            self.diag.err = .{ .NonSymbolCallee = v.items[1] };
                            return error.NonSymbolCallee;
                        }
                        const value = value_sexp.value.symbol;

                        const putres = try fn_ctx.local_symbols.getOrPut(self.arena.allocator(), sym);
                        if (putres.found_existing) {
                            self.diag.err = .{ .DuplicateVariable = code_sexp_idx };
                            return error.DuplicateVariable;
                        } else {
                            const found_type = self.env.getType(value) orelse {
                                self.diag.err = .{ .UndefinedSymbol = v.items[2] };
                                return error.UndefinedSymbol;
                            };
                            putres.value_ptr.* = .{
                                .type = found_type,
                                .index = null,
                            };
                        }

                        break :done;
                    }

                    if (func.value.symbol.ptr == syms.@"return".value.symbol.ptr) {
                        const return_types = switch (fn_ctx.return_type.subtype) {
                            .primitive => &.{fn_ctx.return_type},
                            .@"struct" => |stype| stype.field_types,
                            else => @panic("not yet handled return type"),
                        };

                        for (v.items[1..], return_types) |arg, return_type| {
                            try self.compileExpr(arg, fn_ctx, expr_ctx);
                            self.promoteToTypeInPlace(&self._sexp_compiled[arg], return_type);
                        }

                        slot.type = graphl_builtin.empty_type;
                        // FIXME: support multi value return as struct
                        std.debug.assert(v.items.len == 2);
                        if (v.items.len >= 2) {
                            const last_arg_idx = v.items[v.items.len - 1];
                            // FIXME: check the ExprContext and maybe promote the type...
                            slot.type = self._sexp_compiled[last_arg_idx].type;
                        }

                        // FIXME: construct return tuple type from all arguments
                        const first_arg = self._sexp_compiled[v.items[1]];
                        slot.expr = byn.c.BinaryenReturn(
                            self.module.c(),
                            byn.c.BinaryenLocalGet(self.module.c(), first_arg.local_index, BinaryenHelper.getType(first_arg.type, &self.used_features)),
                        );

                        break :done;
                    }

                    if (func.value.symbol.ptr == syms.begin.value.symbol.ptr) {
                        for (v.items[1..]) |arg| {
                            try self.compileExpr(arg, fn_ctx, expr_ctx);
                        }

                        slot.type = graphl_builtin.empty_type;

                        if (v.items.len >= 2) {
                            const last_arg_idx = v.items[v.items.len - 1];
                            // FIXME: check the ExprContext and maybe promote the type...
                            slot.type = self._sexp_compiled[last_arg_idx].type;
                        }

                        slot.expr = byn.c.BinaryenNop(self.module.c());

                        break :done;
                    }

                    if (func.value.symbol.ptr == syms.define.value.symbol.ptr) {
                        const binding = self.graphlt_module.get(v.items[1]);

                        // no need to compile bindings, they aren't valid expressions
                        // FIXME: add bindings to env
                        for (v.items[2..]) |arg| {
                            try self.compileExpr(arg, fn_ctx, expr_ctx);
                        }

                        switch (binding.value) {
                            // function def
                            .list => {
                                slot.type = fn_ctx.return_type;
                                slot.expr = if (fn_ctx.return_type == graphl_builtin.primitive_types.void)
                                    byn.c.BinaryenNop(self.module.c())
                                else
                                    // add an unreachable to the end of the function def if it must return, since
                                    // it is not possible to reach the end without a return statement
                                    byn.c.BinaryenUnreachable(self.module.c());

                                break :done;
                            },
                            // variable def
                            .symbol => |sym| {
                                // FIXME: check the typeof (via env?) and promote the type...
                                slot.type = graphl_builtin.empty_type;
                                slot.expr = byn.c.BinaryenNop(self.module.c());

                                const last_arg_idx = v.items[v.items.len - 1];
                                const last_arg_slot = &self._sexp_compiled[last_arg_idx];

                                const local_symbol = fn_ctx.local_symbols.getPtr(sym) orelse {
                                    self.diag.err = .{ .DefineWithoutTypeOf = code_sexp_idx };
                                    return error.DefineWithoutTypeOf;
                                };

                                if (local_symbol.index != null) {
                                    self.diag.err = .{ .DuplicateVariable = code_sexp_idx };
                                    return error.DuplicateVariable;
                                }

                                local_symbol.index = local_index;
                                slot.type = local_symbol.type;

                                if (v.items.len == 3) {
                                    // has default to set
                                    slot.type = local_symbol.type;
                                    slot.expr = byn.c.BinaryenLocalSet(
                                        self.module.c(),
                                        local_index,
                                        self.promoteToType(
                                            last_arg_slot.type,
                                            byn.c.BinaryenLocalGet(
                                                self.module.c(),
                                                last_arg_slot.local_index,
                                                BinaryenHelper.getType(last_arg_slot.type, &self.used_features),
                                            ),
                                            slot.type,
                                        ),
                                    );
                                } else if (v.items.len == 2) {
                                    // has no default, leave unset (probably zeroed by wasm maybe)
                                    slot.expr = byn.c.BinaryenNop(self.module.c());
                                } else {
                                    self.diag.err = .{ .BuiltinWrongArity = .{
                                        .callee = v.items[0],
                                        .expected = 2,
                                        .received = @intCast(v.items.len - 1),
                                    } };
                                    return error.BuiltinWrongArity; // FIXME: add diag
                                }

                                break :done;
                            },
                            else => {
                                self.diag.err = .{ .BuiltinWrongArity = .{
                                    .callee = v.items[0],
                                    .expected = 2,
                                    .received = @intCast(v.items.len - 1),
                                } };
                                return error.BuiltinWrongArity; // FIXME: better error
                            },
                        }
                    }

                    // call host functions
                    const func_node_desc = self.env.getNode(func.value.symbol) orelse {
                        log.err("while in:\n{}\n", .{Sexp.withContext(self.graphlt_module, code_sexp_idx)});
                        log.err("undefined symbol1: '{s}'\n", .{func.value.symbol});
                        self.diag.err = .{ .UndefinedSymbol = code_sexp_idx };
                        return error.UndefinedSymbol;
                    };

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
                            if (v.items.len != 4) {
                                std.debug.print("bad if: {}\n", .{Sexp.withContext(self.graphlt_module, code_sexp_idx)});
                                std.debug.panic("bad if: {}\n", .{Sexp.withContext(self.graphlt_module, code_sexp_idx)});
                            }
                            break :_ &if_inputs;
                        } else if (func_node_desc.getInputs().len > 0 and func_node_desc.getInputs()[0].asPrimitivePin() == .exec) {
                            break :_ func_node_desc.getInputs()[1..];
                        } else {
                            break :_ func_node_desc.getInputs();
                        }
                    };

                    var args_top_type = graphl_builtin.empty_type;

                    for (v.items[1..], input_descs) |arg_idx, input_desc| {
                        std.debug.assert(input_desc.asPrimitivePin() == .value);

                        try self.compileExpr(arg_idx, fn_ctx, .{
                            .type = input_desc.asPrimitivePin().value,
                        });
                        const arg_compiled = &self._sexp_compiled[arg_idx];
                        args_top_type = resolvePeerType(args_top_type, arg_compiled.type);
                    }

                    if (func.value.symbol.ptr == syms.@"if".value.symbol.ptr) {
                        slot.type = args_top_type;
                        slot.expr = byn.c.BinaryenNop(self.module.c());
                        break :done;
                    }

                    if (func.value.symbol.ptr == syms.@"set!".value.symbol.ptr) {
                        std.debug.assert(v.items.len == 3);

                        if (self.graphlt_module.get(v.items[1]).value != .symbol) {
                            self.diag.err = .{ .SetNonSymbol = v.items[1] };
                            return error.SetNonSymbol;
                        }

                        // FIXME: leak
                        const set_sym = self.graphlt_module.get(v.items[1]).value.symbol;

                        const local_info = fn_ctx.local_symbols.getPtr(set_sym) orelse {
                            self.diag.err = .{ .UndefinedSymbol = v.items[1] };
                            return error.UndefinedSymbol;
                        };

                        const value_to_set = self._sexp_compiled[v.items[2]];

                        slot.type = graphl_builtin.empty_type;
                        slot.expr = byn.c.BinaryenLocalSet(
                            self.module.c(),
                            local_info.index orelse unreachable,
                            // FIXME: promote value?
                            byn.c.BinaryenLocalGet(self.module.c(), value_to_set.local_index, BinaryenHelper.getType(value_to_set.type, &self.used_features)),
                        );
                        break :done;
                    }

                    inline for (&binaryop_builtins) |builtin_op| {
                        if (func.value.symbol.ptr == builtin_op.sym.value.symbol.ptr) {
                            var op: byn.Expression.Op = undefined;

                            if (v.items.len != 3) {
                                self.diag.err = .{ .BuiltinWrongArity = .{
                                    .callee = v.items[0],
                                    .expected = 2,
                                    .received = @intCast(v.items.len - 1),
                                } };
                                return error.BuiltinWrongArity;
                            }

                            var handled = false;

                            const lhs = &self._sexp_compiled[v.items[1]];
                            const rhs = &self._sexp_compiled[v.items[2]];

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
                                    if (args_top_type == graphl_type) {
                                        const signless = @hasField(@TypeOf(builtin_op), "signless");
                                        const op_name = comptime if (signless and !is_float) builtin_op.wasm_name ++ type_byn_name[1..] else builtin_op.wasm_name ++ type_byn_name;
                                        op = @field(byn.Expression.Op, op_name)();
                                        handled = true;
                                    }
                                }
                            }

                            slot.expr = byn.c.BinaryenLocalSet(
                                self.module.c(),
                                local_index,
                                byn.c.BinaryenBinary(
                                    self.module.c(),
                                    op.c(),
                                    self.promoteToType(
                                        lhs.type,
                                        byn.c.BinaryenLocalGet(self.module.c(), lhs.local_index, BinaryenHelper.getType(lhs.type, &self.used_features)),
                                        args_top_type,
                                    ),
                                    self.promoteToType(
                                        rhs.type,
                                        byn.c.BinaryenLocalGet(self.module.c(), rhs.local_index, BinaryenHelper.getType(rhs.type, &self.used_features)),
                                        args_top_type,
                                    ),
                                ),
                            );

                            // REPORT ME: try to prefer an else on the above for loop, currently couldn't get it to compile right
                            if (!handled) {
                                log.err("unimplemented type resolution: '{s}' for code:\n{}\n", .{ slot.type.name, code_sexp });
                                std.debug.panic("unimplemented type resolution: '{s}'", .{slot.type.name});
                            }

                            if (@hasField(@TypeOf(builtin_op), "result_type")) {
                                slot.type = builtin_op.result_type;
                            } else {
                                slot.type = args_top_type;
                            }

                            break :done;
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
                    //     result.type = outputs[0].kind.primitive.value;

                    //     if (func.value.symbol.ptr == node_desc.name().ptr) {
                    //         const instruct_count: usize = if (result.type == graphl_builtin.empty_type) 1 else 2;
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
                    //         // if (result.type != graphl_builtin.empty_type) {
                    //         //     const local_result_ptr_sym = try context.addLocal(alloc, result.type);

                    //         //     const consume_result = result.values.addOneAssumeCapacity();
                    //         //     consume_result.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                    //         //     try consume_result.value.list.ensureTotalCapacityPrecise(2);
                    //         //     consume_result.value.list.appendAssumeCapacity(wat_syms.ops.@"local.set");
                    //         //     consume_result.value.list.appendAssumeCapacity(local_result_ptr_sym);
                    //         // }

                    //         break :done;
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

                        slot.type =
                            if (is_pure) outputs[0].kind.primitive.value
                                //
                            else if (is_simple_0_out_impure)
                                primitive_types.void
                                    //
                            else if (is_simple_1_out_impure)
                                outputs[1].kind.primitive.value
                                    //
                            else {
                                std.debug.print("func={s}\n", .{func_node_desc.name()});
                                return error.UnimplementedMultiResultHostFunc;
                            };

                        //const operands = try self.arena.allocator().alloc(byn.c.BinaryenExpressionRef, v.items.len - 1 + @as(usize, if (requires_drop) 1 else 0));
                        const operands = try self.arena.allocator().alloc(byn.c.BinaryenExpressionRef, v.items.len - 1);
                        defer self.arena.allocator().free(operands);

                        for (v.items[1..], operands[0 .. v.items.len - 1]) |arg_idx, *operand| {
                            const arg_compiled = self._sexp_compiled[arg_idx];
                            operand.* = byn.c.BinaryenLocalGet(self.module.c(), arg_compiled.local_index, BinaryenHelper.getType(arg_compiled.type, &self.used_features));
                        }

                        // if (requires_drop) {
                        //     operands[operands.len - 1] = @ptrCast(byn.c.BinaryenDrop(
                        //         self.module.c(),
                        //         // FIXME: why does Drop take an argument? is that a WAST thing?
                        //         byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(0)),
                        //     ));
                        // }

                        const call_expr = byn.c.BinaryenCall(
                            self.module.c(),
                            func.value.symbol,
                            operands.ptr,
                            @intCast(operands.len),
                            BinaryenHelper.getType(slot.type, &self.used_features),
                        );

                        slot.expr = if (slot.type == primitive_types.void)
                            call_expr
                        else
                            byn.c.BinaryenLocalSet(self.module.c(), local_index, call_expr);

                        break :done;
                    }

                    // otherwise we have a non builtin
                    log.err("unhandled call: {}", .{code_sexp});
                    return error.UnhandledCall;
                },

                .int => |v| {
                    slot.type = primitive_types.i32_;
                    slot.expr = byn.c.BinaryenLocalSet(self.module.c(), local_index, byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@intCast(v))));
                },

                .float => |v| {
                    slot.type = primitive_types.f64_;
                    slot.expr = byn.c.BinaryenLocalSet(self.module.c(), local_index, byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralFloat64(v)));
                },

                .symbol => |v| {
                    // FIXME: have a list of symbols in the scope
                    if (v.ptr == syms.true.value.symbol.ptr) {
                        slot.type = primitive_types.bool_;
                        slot.expr = byn.c.BinaryenLocalSet(self.module.c(), local_index, byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(1)));
                        break :done;
                    }

                    if (v.ptr == syms.false.value.symbol.ptr) {
                        slot.type = primitive_types.bool_;
                        slot.expr = byn.c.BinaryenLocalSet(self.module.c(), local_index, byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(0)));
                        break :done;
                    }

                    const Info = struct {
                        type: Type,
                        ref: u32,
                    };

                    const info = _: {
                        // TODO: use the env
                        if (fn_ctx.local_symbols.getPtr(v)) |local_entry| {
                            break :_ Info{
                                .type = local_entry.type,
                                .ref = local_entry.index orelse unreachable,
                            };
                        }
                        self.diag.err = .{ .UndefinedSymbol = code_sexp_idx };
                        return error.UndefinedSymbol;
                    };

                    slot.type = info.type;
                    slot.expr = byn.c.BinaryenLocalSet(self.module.c(), local_index, byn.c.BinaryenLocalGet(self.module.c(), info.ref, BinaryenHelper.getType(info.type, &self.used_features)));
                },

                .borrowedString, .ownedString => |v| {
                    // try self.arena.allocator().dupeZ(u8, v),

                    // python: 10 == len(str(2**32 - 1)), could use comptime print to assert
                    var buf: ["s_".len + 10 + "\x00".len]u8 = undefined;
                    const seg_name = std.fmt.bufPrintZ(&buf, "s_{}", .{self.ro_data_offset}) catch unreachable;

                    // FIXME: do string deduplication/interning
                    byn.c.BinaryenAddDataSegment(
                        self.module.c(),
                        seg_name,
                        main_mem_name,
                        true,
                        null,
                        // FIXME: gross, use 0 terminated strings?
                        v.ptr,
                        @intCast(v.len),
                    );

                    // FIXME: add fixed data and copy from it
                    slot.expr = byn.c.BinaryenLocalSet(
                        self.module.c(),
                        local_index,
                        byn.c.BinaryenArrayNewData(
                            self.module.c(),
                            byn.c.BinaryenTypeGetHeapType(BinaryenHelper.getType(primitive_types.string, &self.used_features)),
                            seg_name,
                            // TODO: consider using an offset?
                            byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(0)),
                            byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@intCast(v.len))),
                        ),
                    );

                    // TODO: handle overflow
                    self.ro_data_offset = std.math.add(u32, self.ro_data_offset, @intCast(v.len)) catch @panic("ro_data_offset overflow");

                    slot.type = primitive_types.string;
                },

                .bool => |v| {
                    slot.type = primitive_types.bool_;
                    slot.expr = byn.c.BinaryenLocalSet(
                        self.module.c(),
                        local_index,
                        byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(if (v) 1 else 0)),
                    );
                },

                .jump => {
                    slot.type = graphl_builtin.empty_type;
                    //  FIXME: turn on!
                    // FIXME: probably post block of jump should be unreachable?
                    //slot.expr = byn.c.BinaryenNop(self.module.c());
                    slot.expr = byn.c.BinaryenUnreachable(self.module.c());
                },

                inline else => {
                    log.err("unimplemented expr for compilation:\n{}\n", .{code_sexp});
                    std.debug.panic("unimplemented type: '{s}'", .{@tagName(code_sexp.value)});
                },
            }
        }

        try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);

        slot.pre_block = byn.c.RelooperAddBlock(fn_ctx.relooper, byn.c.BinaryenNop(self.module.c()));
        slot.post_block = byn.c.RelooperAddBlock(fn_ctx.relooper, slot.expr);
    }

    // find the nearest super type (if any) of two types
    fn resolvePeerType(a: Type, b: Type) Type {
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

            log.warn("unimplemented peer type resolution: {s} & {s}", .{ a.name, b.name });
            // FIXME: have a special any type?
            // e.g. see the type theoretical concepts of top types
            break :_ graphl_builtin.empty_type;
        };

        return resolved_type;
    }

    fn promoteToTypeInPlace(self: *@This(), slot: *Slot, target_type: Type) void {
        slot.expr = self.promoteToType(slot.type, slot.expr, target_type);
        slot.type = target_type;
    }

    // TODO: use an actual type graph/tree and search in it
    fn promoteToType(
        self: *@This(),
        start_type: Type,
        expr: byn.c.BinaryenExpressionRef,
        target_type: Type,
    ) byn.c.BinaryenExpressionRef {
        var curr_type = start_type;
        var curr_expr = expr;
        var i: usize = 0;
        const MAX_ITERS = 128;
        while (curr_type != target_type) : (i += 1) {
            if (i > MAX_ITERS) {
                log.err("max iters resolving types: {s} -> {s}", .{ curr_type.name, target_type.name });
                std.debug.panic("max iters resolving types: {s} -> {s}", .{ curr_type.name, target_type.name });
            }

            if (curr_type == primitive_types.bool_) {
                curr_type = primitive_types.i32_;
                continue;
            }

            var op: byn.Expression.Op = undefined;

            if (curr_type == primitive_types.i32_) {
                op = byn.Expression.Op.extendSInt32();
                curr_type = primitive_types.i64_;
            } else if (curr_type == primitive_types.i64_) {
                op = byn.Expression.Op.convertSInt64ToFloat32();
                curr_type = primitive_types.f32_;
            } else if (curr_type == primitive_types.u32_) {
                op = byn.Expression.Op.extendUInt32();
                curr_type = primitive_types.i64_;
            } else if (curr_type == primitive_types.u64_) {
                op = byn.Expression.Op.convertUInt64ToFloat32();
                curr_type = primitive_types.f32_;
            } else if (curr_type == primitive_types.f32_) {
                op = byn.Expression.Op.promoteFloat32();
                curr_type = primitive_types.f64_;
            } else {
                log.err("unimplemented type promotion: {s} -> {s}", .{ curr_type.name, target_type.name });
                std.debug.panic("unimplemented type promotion: {s} -> {s}", .{ curr_type.name, target_type.name });
            }

            curr_expr = byn.c.BinaryenUnary(self.module.c(), op.c(), curr_expr);
        }

        return curr_expr;
    }

    // resolve the peer type of the fragments, then augment the fragment to be casted to that resolved peer
    fn resolvePeerTypesWithPromotions(self: *@This(), a: *Slot, b: *Slot) !Type {
        if (a.type == graphl_builtin.empty_type)
            return b.type;

        if (b.type == graphl_builtin.empty_type)
            return a.type;

        if (a.type == b.type)
            return a.type;

        // REPORT: zig can't switch on constant pointers
        const resolved_type = resolvePeerType(a.type, b.type);

        inline for (&.{ a, b }) |fragment| {
            self.promoteToTypeInPlace(fragment, resolved_type);
        }

        return resolved_type;
    }

    // FIXME: unused
    const ExprContext = struct {
        // FIXME: unused
        // TODO: rename to unresolved_type
        type: Type = graphl_builtin.empty_type,
    };

    const FnContext = struct {
        _frame_byte_size: u32 = 0,
        relooper: *byn.c.struct_Relooper,
        /// NOTE: should be the same as param_count initially
        next_sexp_local_idx: u32,
        param_count: u16,

        /// the type for each wasm local index, e.g. for each node
        local_types: *std.ArrayListUnmanaged(Type),
        /// map of graphl symbols to the type and wasm local holding it
        local_symbols: *SymMapUnmanaged(LocalInfo),

        return_type: Type,

        pub const LocalInfo = struct {
            index: ?byn.c.BinaryenIndex = null,
            type: Type,
        };

        // FIXME: put into local_symbols as well? (or use env?)
        /// returns the index of the wasm local holding the value on the frame
        pub fn putLocalForSexp(self: *@This(), comp_ctx: *const Compilation, sexp_idx: u32) byn.c.BinaryenIndex {
            const local_index = self.next_sexp_local_idx;
            self.next_sexp_local_idx += 1;
            const slot = &comp_ctx._sexp_compiled[sexp_idx];
            slot.local_index = local_index;
            return local_index;
        }

        pub fn finalizeSlotTypeForSexp(self: *@This(), comp_ctx: *Compilation, sexp_idx: u32) !void {
            const slot = &comp_ctx._sexp_compiled[sexp_idx];
            //std.debug.assert(slot.type != graphl_builtin.empty_type);
            if (!slot.type.isPrimitive()) {
                slot.frame_depth = self._frame_byte_size;
                self._frame_byte_size += slot.type.size;
            }

            const idx_in_local_types = slot.local_index - self.param_count;
            try self.local_types.ensureTotalCapacityPrecise(comp_ctx.arena.allocator(), idx_in_local_types + 1);
            self.local_types.expandToCapacity();
            self.local_types.items[idx_in_local_types] = slot.type;
        }
    };

    const CompileExprError = std.mem.Allocator.Error || Diagnostic.Code;

    fn RelooperAddBranch(
        self: *const @This(),
        from_idx: u32,
        comptime from_side: enum { pre, post },
        to_idx: u32,
        comptime to_side: enum { pre, post },
        condition: byn.c.BinaryenExpressionRef,
        code: byn.c.BinaryenExpressionRef,
    ) void {
        const from_slot = &self._sexp_compiled[from_idx];
        const from_block = if (from_side == .pre) from_slot.pre_block else from_slot.post_block;
        const to_slot = &self._sexp_compiled[to_idx];
        const to_block = if (to_side == .pre) to_slot.pre_block else to_slot.post_block;
        if (builtin.mode == .Debug) {
            std.debug.print("from:0x{x}->to:0x{x}\n", .{ @intFromPtr(from_block), @intFromPtr(to_block) });
            std.debug.print("from:{s}:{}: {}\nto:{s}:{}: {}\n", .{
                @tagName(from_side),
                from_idx,
                Sexp.printOneLine(self.graphlt_module, from_idx),
                @tagName(to_side),
                to_idx,
                Sexp.printOneLine(self.graphlt_module, to_idx),
            });
        }
        byn.c.RelooperAddBranch(from_block, to_block, condition, code);
    }

    // link (recursively) a sexp's control flow and then jump to the "done_block"
    // - "if" will have conditional jumps and then both blocks jump to the "done_block"
    // - jumps just jump
    // - all dependencies (typically arguments) are executed first in order
    fn linkExpr(
        self: *@This(),
        code_sexp_idx: u32,
        context: *FnContext,
        // FIXME: not used, maybe add a force return block to the context and use that?
        done_block: byn.c.RelooperBlockRef,
    ) CompileExprError!void {
        _ = done_block;

        const code_sexp = self.graphlt_module.get(code_sexp_idx);
        const slot = &self._sexp_compiled[code_sexp_idx];

        switch (code_sexp.value) {
            .jump => |j| {
                // NOTE: post_block unused for jumps
                self.RelooperAddBranch(code_sexp_idx, .pre, j.target, .pre, null, null);
            },
            .list => |list| {
                if (list.items.len == 0) {
                    self.diag.err = .{ .EmptyCall = code_sexp_idx };
                    return error.EmptyCall;
                }

                const callee_idx = list.items[0];
                const callee = self.graphlt_module.get(callee_idx);
                std.debug.assert(callee.value == .symbol);

                // is typeof
                if (callee.value.symbol.ptr == syms.typeof.value.symbol.ptr) {
                    self.RelooperAddBranch(code_sexp_idx, .pre, code_sexp_idx, .post, null, null);
                    return;
                } else if (callee.value.symbol.ptr == syms.define.value.symbol.ptr and list.items.len >= 2 and self.graphlt_module.get(list.items[1]).value == .symbol) {
                    try self.linkExpr(list.items[2], context, slot.post_block);
                    self.RelooperAddBranch(code_sexp_idx, .pre, list.items[2], .pre, null, null);
                    self.RelooperAddBranch(list.items[2], .post, code_sexp_idx, .post, null, null);
                    return;
                } else if (callee.value.symbol.ptr == syms.@"if".value.symbol.ptr) {
                    std.debug.assert(list.items.len >= 3);
                    const condition_idx = code_sexp.value.list.items[1];
                    const condition_slot = &self._sexp_compiled[condition_idx];
                    const consequence_idx = code_sexp.value.list.items[2];
                    self.RelooperAddBranch(code_sexp_idx, .pre, condition_idx, .pre, null, null);
                    self.RelooperAddBranch(
                        condition_idx,
                        .post,
                        consequence_idx,
                        .pre,
                        byn.c.BinaryenLocalGet(self.module.c(), condition_slot.local_index, BinaryenHelper.getType(condition_slot.type, &self.used_features)),
                        null,
                    );
                    self.RelooperAddBranch(consequence_idx, .post, code_sexp_idx, .post, null, null);
                    try self.linkExpr(consequence_idx, context, slot.post_block);
                    if (list.items.len > 3) {
                        const alternative_idx = code_sexp.value.list.items[3];
                        try self.linkExpr(condition_idx, context, self._sexp_compiled[alternative_idx].pre_block);
                        try self.linkExpr(alternative_idx, context, slot.post_block);
                        self.RelooperAddBranch(condition_idx, .post, alternative_idx, .pre, null, null);
                    } else {
                        try self.linkExpr(condition_idx, context, slot.post_block);
                        self.RelooperAddBranch(condition_idx, .post, code_sexp_idx, .pre, null, null);
                    }
                } else { // otherwise begin, return, define, or function call // TODO: macros
                    const items = if (callee.value.symbol.ptr == syms.define.value.symbol.ptr) list.items[2..] else list.items[1..];

                    for (items) |item| {
                        try self.linkExpr(item, context, slot.post_block);
                    }

                    for (items[0 .. items.len - 1], items[1..]) |prev, next| {
                        self.RelooperAddBranch(prev, .post, next, .pre, null, null);
                    }

                    if (items.len > 0) {
                        const first_item = items[0];
                        self.RelooperAddBranch(code_sexp_idx, .pre, first_item, .pre, null, null);
                        const last_item = items[items.len - 1];
                        self.RelooperAddBranch(last_item, .post, code_sexp_idx, .post, null, null);
                    } else {
                        self.RelooperAddBranch(code_sexp_idx, .pre, code_sexp_idx, .post, null, null);
                    }
                }
            },
            .module => unreachable,
            else => {
                self.RelooperAddBranch(code_sexp_idx, .pre, code_sexp_idx, .post, null, null);
            },
        }

        // const has_value = switch (code_sexp.value) {
        //     .list => |list| _: {
        //         if (list.items.len == 0) break :_ true;
        //         // NOTE: only in a quote/macro context can this be not a symbol
        //         const callee = self.graphlt_module.get(list.items[0]).value.symbol;

        //         // FIXME: ignore these better
        //         if (callee.ptr == pool.getSymbol("begin").ptr) break :_ false;
        //         if (callee.ptr == pool.getSymbol("return").ptr) break :_ false;

        //         const def = self.env.getNode(callee) orelse {
        //             self.diag.err = .{ .UndefinedSymbol = list.items[0] };
        //             return error.UndefinedSymbol;
        //         };
        //         for (def.getOutputs()) |o| {
        //             if (!o.isExec()) break :_ true;
        //         }
        //         break :_ false;
        //     },
        //     else => true, // FIXME: confirm
        // };

        // if (slot_res.found_existing) {
        //     if (has_value and slot_res.value_ptr.type == graphl_builtin.empty_type)
        //         // TODO: diagnostic
        //         return error.RecursiveDependency;

        //     slot.expr = byn.c.BinaryenLocalGet(self.module.c(), slot.local_index, BinaryenHelper.getType(slot.type, &self.used_features));
        //     slot.type = primitive_types.code;
        //     return;
        // }

        // const fragment = frag: {
        //     // FIXME: destroy this
        //     // HACK: oh god this is bad...
        //     const is_macro_hack = code_sexp.label != null and code_sexp.value == .list
        //         //
        //     and code_sexp.value.list.items.len > 0
        //         //
        //     and code_sexp.getWithModule(0, self.graphlt_module).value == .symbol
        //         //
        //     and _: {
        //         const sym = code_sexp.getWithModule(0, self.graphlt_module).value.symbol;
        //         inline for (&.{ "SELECT", "WHERE", "FROM" }) |hack| {
        //             if (sym.ptr == pool.getSymbol(hack).ptr)
        //                 break :_ true;
        //         }
        //         break :_ false;
        //     };

        //     if (is_macro_hack) {
        //         const fragment = Fragment{
        //             .expr = byn.c.BinaryenNop(self.module.c()),
        //             .type = primitive_types.code,
        //         };

        //         // FIXME: remove this?
        //         const entry = try context.label_map.getOrPut(code_sexp.label.?[2..]);
        //         std.debug.assert(!entry.found_existing);

        //         entry.value_ptr.* = .{
        //             .fragment = fragment,
        //             .sexp = code_sexp,
        //         };

        //         break :frag fragment;
        //     }

        //     break :frag try self.compileExpr(code_sexp_idx, context);
        // };
    }

    const ExprBlock = struct {
        //FIXME: remove
        //exprs: []byn.c.BinaryenExpressionRef,
        type: Type,
    };

    fn isControlFlow(mod_ctx: *const ModuleContext, sexp: *const Sexp) bool {
        switch (sexp.value) {
            .list => |list| {
                if (list.items.len == 0) return false;
                const callee = mod_ctx.get(list.items[0]);
                if (callee.value == .symbol and callee.value.symbol.ptr == syms.@"if".value.symbol.ptr)
                    return true;
            },
            .jump => return true,
            else => {},
        }
        return false;
    }

    fn compileTypeOfVar(self: *@This(), sexp: *const Sexp) !bool {
        // std.debug.assert(sexp.value == .list);
        // std.debug.assert(sexp.value.list.items[0].value == .symbol);
        // // FIXME: parser should be aware of the define form!
        // //std.debug.assert(sexp.value.list.items[0].value.symbol.ptr == syms.typeof.value.symbol.ptr);
        // std.debug.assert(std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.typeof.value.symbol));

        // if (sexp.value.list.items[1].value != .symbol) return false;
        // if (sexp.value.list.items[2].value != .symbol) return error.VarTypeNotSymbol;

        const var_name = sexp.getWithModule(1, self.graphlt_module).value.symbol;
        _ = var_name;
        const type_name = sexp.getWithModule(2, self.graphlt_module).value.symbol;
        _ = type_name;

        // FIXME: implement

        return true;
    }

    const Optimize = enum { size, speed, none };

    const Opts = struct {
        optimize: Optimize = .none,
    };

    pub fn compileModule(self: *@This(), graphlt_module: *const ModuleContext, opts: Opts) ![]const u8 {
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
                param_types[0] = byn.c.BinaryenTypeInt32();
                for (_self.params, param_types[1..]) |graphl_t, *wasm_t| {
                    wasm_t.* = BinaryenHelper.getType(graphl_t, &ctx.used_features);
                }
                const params: byn.c.BinaryenType = byn.c.BinaryenTypeCreate(param_types.ptr, @intCast(param_types.len));

                const result_types = try ctx.arena.allocator().alloc(byn.c.BinaryenType, _self.results.len);
                defer ctx.arena.allocator().free(result_types); // FIXME: what is the binaryen ownership model?
                for (_self.results, result_types) |graphl_t, *wasm_t| {
                    wasm_t.* = BinaryenHelper.getType(graphl_t, &ctx.used_features);
                }
                const results: byn.c.BinaryenType = byn.c.BinaryenTypeCreate(result_types.ptr, @intCast(result_types.len));

                byn.c.BinaryenAddFunctionImport(ctx.module.c(), in_name, "env", in_name, params, results);
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
                const byn_params = try self.arena.allocator().alloc(byn.c.BinaryenType, params.len);
                const byn_results = try self.arena.allocator().alloc(byn.c.BinaryenType, results.len);

                for (params, def.params, byn_params) |param, *param_type, *byn_param| {
                    param_type.* = param.kind.primitive.value;
                    byn_param.* = BinaryenHelper.getType(param.kind.primitive.value, &self.used_features);
                }
                for (results, def.results, byn_results) |result, *result_type, *byn_result| {
                    result_type.* = result.kind.primitive.value;
                    byn_result.* = BinaryenHelper.getType(result.kind.primitive.value, &self.used_features);
                }

                var byn_args = try std.ArrayListUnmanaged(*byn.Expression).initCapacity(self.arena.allocator(), byn_params.len + 1);
                defer byn_args.deinit(self.arena.allocator());
                byn_args.appendAssumeCapacity(@ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@intCast(user_func.data.id)))));
                byn_args.expandToCapacity();

                for (params, 0.., byn_args.items[1..]) |p, i, *byn_arg| {
                    byn_arg.* = byn.Expression.localGet(self.module, @intCast(i), @enumFromInt(BinaryenHelper.getType(p.kind.primitive.value, &self.used_features)));
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
                        byn_result,
                    )),
                );

                std.debug.assert(func != null);
            }
        }

        for (graphlt_module.getRoot().value.module.items) |idx| {
            const decl = graphlt_module.get(idx);
            switch (decl.value) {
                .list => {
                    // FIXME: maybe distinguish without errors if something if a func, var or typeof?
                    const did_compile = (try self.compileFunc(idx) or
                        try self.compileVar(idx) or
                        try self.compileTypeOf(idx) or
                        try self.compileMeta(idx) or
                        try self.compileImport(decl));
                    if (!did_compile) {
                        self.diag.err = Diagnostic.Error{ .BadTopLevelForm = idx };
                        log.err("{}", .{self.diag});
                        return error.badTopLevelForm;
                    }
                },
                else => {
                    self.diag.err = Diagnostic.Error{ .BadTopLevelForm = idx };
                    log.err("{}", .{self.diag});
                    log.err("{}", .{self.diag});
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

        if (self.used_features.vec3) {
            const vec3_module = byn.c.BinaryenModuleRead(@constCast(intrinsics_vec3.ptr), intrinsics_vec3.len);

            // FIXME: replace with generic struct breaking
            std.debug.assert(byn._binaryenCloneFunction(vec3_module, self.module.c(), "__graphl_vec3_x".ptr, "Vec3->X".ptr));
            std.debug.assert(byn._binaryenCloneFunction(vec3_module, self.module.c(), "__graphl_vec3_y".ptr, "Vec3->Y".ptr));
            std.debug.assert(byn._binaryenCloneFunction(vec3_module, self.module.c(), "__graphl_vec3_z".ptr, "Vec3->Z".ptr));
        }

        if (std.log.logEnabled(.debug, .graphlt_compiler)) {
            byn._BinaryenModulePrintStderr(self.module.c());
        }

        if (opts.optimize != .none) {
            byn.c.BinaryenModuleOptimize(self.module.c());
        }

        if (!byn._BinaryenModuleValidateWithOpts(
            self.module.c(),
            @enumFromInt( //@intFromEnum(byn.Flags.quiet) |
            @intFromEnum(byn.Flags.globally)),
        )) {
            self.diag.err = .InvalidIR;
            return error.InvalidIR;
        }

        // FIXME: make the arena in this function instead of in the caller
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
    graphlt_module: *const ModuleContext,
    user_funcs: ?*const std.SinglyLinkedList(UserFunc),
    _in_diagnostic: ?*Diagnostic,
) ![]const u8 {
    if (build_opts.disable_compiler) unreachable;
    var ignored_diagnostic: Diagnostic = undefined; // FIXME: why don't we init?
    const diag = if (_in_diagnostic) |d| d else &ignored_diagnostic;
    diag.graphlt_module = graphlt_module;

    // FIXME: use the arena inside the compilation instead of the raw allocator
    var env = try Env.initDefault(a);
    defer env.deinit(a);

    var unit = try Compilation.init(a, graphlt_module, &env, user_funcs, diag);
    defer unit.deinit();

    // FIXME: make optimize an option
    return unit.compileModule(graphlt_module, .{
        .optimize = .none,
    });
}

test "compile big" {
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
        \\; comment
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
        \\               10))))
        \\
    , null);
    //std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit();

    const expected =
        \\(module
        \\  (type (;0;) (array (mut i8)))
        \\  (type (;1;) (func (param i32) (result i32)))
        \\  (type (;2;) (func (param (ref null 0))))
        \\  (type (;3;) (func (param i32)))
        \\  (type (;4;) (func (param f32 f32) (result f32)))
        \\  (type (;5;) (func (param i32 (ref null 0))))
        \\  (type (;6;) (func (param i32 i32)))
        \\  (type (;7;) (func (param i32) (result f64)))
        \\  (import "env" "callUserFunc_code_R" (func (;0;) (type 5)))
        \\  (import "env" "callUserFunc_i32_R" (func (;1;) (type 6)))
        \\  (memory (;0;) 1 256)
        \\  (export "memory" (memory 0))
        \\  (export "++" (func $++))
        \\  (export "deep" (func $deep))
        \\  (export "ifs" (func $ifs))
        \\  (func $sql (;2;) (type 2) (param (ref null 0))
        \\    i32.const 1
        \\    local.get 0
        \\    call 0
        \\  )
        \\  (func $Confetti (;3;) (type 3) (param i32)
        \\    i32.const 0
        \\    local.get 0
        \\    call 1
        \\  )
        \\  (func $++ (;4;) (type 1) (param i32) (result i32)
        \\    (local i32 i32 i32 i32 i32 i32 i32)
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        i32.const 100
        \\        local.set 3
        \\        local.get 3
        \\        call $Confetti
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      local.get 0
        \\      local.set 6
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        block ;; label = @3
        \\          i32.const 1
        \\          local.set 7
        \\          local.get 6
        \\          local.get 7
        \\          i32.add
        \\          local.set 5
        \\        end
        \\        local.get 5
        \\        return
        \\      end
        \\      unreachable
        \\    end
        \\    unreachable
        \\  )
        \\  (func $deep (;5;) (type 4) (param f32 f32) (result f32)
        \\    (local f32 f32 f32 f32 f32 f32 f32 f32 f32 i32)
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      local.get 0
        \\      local.set 7
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        i32.const 10
        \\        local.set 11
        \\        local.get 7
        \\        local.get 11
        \\        i64.extend_i32_s
        \\        f32.convert_i64_s
        \\        f32.div
        \\        local.set 6
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      local.get 0
        \\      local.set 9
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        block ;; label = @3
        \\          local.get 1
        \\          local.set 10
        \\          local.get 9
        \\          local.get 10
        \\          f32.mul
        \\          local.set 8
        \\        end
        \\        local.get 6
        \\        local.get 8
        \\        f32.add
        \\        local.set 5
        \\        local.get 5
        \\        return
        \\      end
        \\      unreachable
        \\    end
        \\    unreachable
        \\  )
        \\  (func $ifs (;6;) (type 1) (param i32) (result i32)
        \\    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      local.get 0
        \\      local.set 4
        \\      local.get 4
        \\      if ;; label = @2
        \\        br 1 (;@1;)
        \\      else
        \\        block ;; label = @3
        \\          block ;; label = @4
        \\            i32.const 200
        \\            local.set 11
        \\            local.get 11
        \\            call $Confetti
        \\          end
        \\          br 0 (;@3;)
        \\        end
        \\        i32.const 10
        \\        local.set 12
        \\      end
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        i32.const 100
        \\        local.set 6
        \\        local.get 6
        \\        call $Confetti
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      i32.const 2
        \\      local.set 8
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        i32.const 3
        \\        local.set 9
        \\        local.get 8
        \\        local.get 9
        \\        i32.add
        \\        local.set 7
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    unreachable
        \\  )
        \\  (func $Vec3->X (;7;) (type 7) (param i32) (result f64)
        \\    local.get 0
        \\    f64.load
        \\  )
        \\  (@custom "sourceMappingURL" (after code) "\07/script")
        \\)
        \\
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed.module, &user_funcs, &diagnostic)) |wasm| {
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

    // TODO: add a wasmtools dependency
    const wasmtools_run = try std.process.Child.run(.{
        .allocator = t.allocator,
        .argv = &.{ "wasm-tools", "print", "/tmp/compiler-test.wasm", "-o", "/tmp/compiler-test.wat" },
    });
    defer t.allocator.free(wasmtools_run.stdout);
    defer t.allocator.free(wasmtools_run.stderr);
    if (!std.meta.eql(wasmtools_run.term, .{ .Exited = 0 })) {
        std.debug.print("wasmtools exited with {any}:\n{s}\n", .{ wasmtools_run.term, wasmtools_run.stderr });
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

test "factorial recursive" {
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
    defer parsed.deinit();

    const expected =
        \\(module
        \\  (type (;0;) (func (param i32) (result i32)))
        \\  (type (;1;) (func (param i32) (result f64)))
        \\  (memory (;0;) 1 256)
        \\  (export "memory" (memory 0))
        \\  (export "factorial" (func 0))
        \\  (func (;0;) (type 0) (param i32) (result i32)
        \\    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      local.get 0
        \\      local.set 5
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        i32.const 1
        \\        local.set 6
        \\        local.get 5
        \\        local.get 6
        \\        i32.le_s
        \\        local.set 4
        \\      end
        \\      local.get 4
        \\      if ;; label = @2
        \\        block ;; label = @3
        \\          block ;; label = @4
        \\            i32.const 1
        \\            local.set 9
        \\            local.get 9
        \\            return
        \\          end
        \\          unreachable
        \\        end
        \\      else
        \\        br 1 (;@1;)
        \\      end
        \\    end
        \\    block ;; label = @1
        \\      local.get 0
        \\      local.set 13
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      local.get 0
        \\      local.set 16
        \\      br 0 (;@1;)
        \\    end
        \\    i32.const 1
        \\    local.set 17
        \\    local.get 16
        \\    local.get 17
        \\    i32.sub
        \\    local.set 15
        \\    local.get 15
        \\    call 0
        \\    local.set 14
        \\    local.get 13
        \\    local.get 14
        \\    i32.mul
        \\    local.set 12
        \\    local.get 12
        \\    return
        \\  )
        \\  (func (;1;) (type 1) (param i32) (result f64)
        \\    local.get 0
        \\    f64.load
        \\  )
        \\  (@custom "sourceMappingURL" (after code) "\07/script")
        \\)
        \\
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed.module, null, &diagnostic)) |wasm| {
        defer t.allocator.free(wasm);
        try expectWasmEqualsWat(expected, wasm);
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}

test "factorial iterative" {
    var parsed = try SexpParser.parse(t.allocator,
        \\(meta version 1)
        \\(typeof (factorial i64) i64)
        \\(define (factorial n)
        \\  (typeof acc i64)
        \\  (define acc 1)
        \\  <!if
        \\  (if (<= n 1)
        \\      (return acc)
        \\      (begin
        \\        (set! acc (* acc n))
        \\        (set! n (- n 1))
        \\        >!if)))
        \\
    , null);
    //std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit();

    const expected =
        \\(module
        \\  (type (;0;) (func (param i64) (result i64)))
        \\  (type (;1;) (func (param i32) (result f64)))
        \\  (memory (;0;) 1 256)
        \\  (export "memory" (memory 0))
        \\  (export "factorial" (func $factorial))
        \\  (func $factorial (;0;) (type 0) (param i64) (result i64)
        \\    (local i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 i32 i32 i32 i32 i32 i32 i32 i32 i32)
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        i32.const 1
        \\        local.set 15
        \\        local.get 15
        \\        i64.extend_i32_s
        \\        local.set 2
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      loop ;; label = @2
        \\        block ;; label = @3
        \\          local.get 0
        \\          local.set 4
        \\          br 0 (;@3;)
        \\        end
        \\        block ;; label = @3
        \\          block ;; label = @4
        \\            i32.const 1
        \\            local.set 17
        \\            local.get 4
        \\            local.get 17
        \\            i64.extend_i32_s
        \\            i64.le_s
        \\            local.set 16
        \\          end
        \\          local.get 16
        \\          if ;; label = @4
        \\            br 3 (;@1;)
        \\          else
        \\            br 1 (;@3;)
        \\          end
        \\          unreachable
        \\        end
        \\        block ;; label = @3
        \\          local.get 2
        \\          local.set 7
        \\          br 0 (;@3;)
        \\        end
        \\        block ;; label = @3
        \\          local.get 2
        \\          local.set 9
        \\          br 0 (;@3;)
        \\        end
        \\        block ;; label = @3
        \\          block ;; label = @4
        \\            block ;; label = @5
        \\              local.get 0
        \\              local.set 10
        \\              local.get 9
        \\              local.get 10
        \\              i64.mul
        \\              local.set 8
        \\            end
        \\            local.get 8
        \\            local.set 2
        \\          end
        \\          br 0 (;@3;)
        \\        end
        \\        block ;; label = @3
        \\          local.get 0
        \\          local.set 11
        \\          br 0 (;@3;)
        \\        end
        \\        block ;; label = @3
        \\          local.get 0
        \\          local.set 13
        \\          br 0 (;@3;)
        \\        end
        \\        i32.const 1
        \\        local.set 21
        \\        local.get 13
        \\        local.get 21
        \\        i64.extend_i32_s
        \\        i64.sub
        \\        local.set 12
        \\        local.get 12
        \\        local.set 0
        \\        br 0 (;@2;)
        \\      end
        \\      unreachable
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        local.get 2
        \\        local.set 6
        \\        local.get 6
        \\        return
        \\      end
        \\      unreachable
        \\    end
        \\    unreachable
        \\  )
        \\  (func $Vec3->X (;1;) (type 1) (param i32) (result f64)
        \\    local.get 0
        \\    f64.load
        \\  )
        \\  (@custom "sourceMappingURL" (after code) "\07/script")
        \\)
        \\
    ;

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed.module, null, &diagnostic)) |wasm| {
        defer t.allocator.free(wasm);
        try expectWasmEqualsWat(expected, wasm);
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

    var parsed = try SexpParser.parse(t.allocator,
        \\(meta version 1)
        \\(import ModelCenter "host/ModelCenter")
        \\
        \\(typeof (processInstance u64
        \\                         vec3
        \\                         vec3)
        \\        string)
        \\(define (processInstance MeshId
        \\                         Origin
        \\                         Rotation)
        \\        (begin (ModelCenter) <!__label1
        \\               (if (> (Vec3->X #!__label1)
        \\                      2)
        \\                   (begin (return "my_export"))
        \\                   (begin (return "EXPORT2")))))
    , null);
    //std.debug.print("{any}\n", .{parsed});
    // FIXME: there is some double-free happening here?
    defer parsed.deinit();

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
    if (compile(t.allocator, &parsed.module, &user_funcs, &diagnostic)) |wasm| {
        defer t.allocator.free(wasm);
        try expectWasmEqualsWat(expected, wasm);
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
        try t.expect(false);
    }
}

// TODO: maybe shell out to local wasmtime or node installation?
// or use orca?
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

    const wasmtools_run = try std.process.Child.run(.{
        .allocator = t.allocator,
        .argv = &.{ "wasm-tools", "print", "/tmp/compiler-test.wat", "-o", "/tmp/compiler-test.wasm" },
    });
    defer t.allocator.free(wasmtools_run.stdout);
    defer t.allocator.free(wasmtools_run.stderr);
    if (!std.meta.eql(wasmtools_run.term, .{ .Exited = 0 })) {
        std.debug.print("wasmtools exited with {any}:\n{s}\n", .{ wasmtools_run.term, wasmtools_run.stderr });
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
    //t.refAllDecls(@import("./compiler-tests-string.zig"));
    t.refAllDecls(@import("./compiler-tests-types.zig"));
}

const bytebox = @import("bytebox");
const byn = @import("binaryen");
