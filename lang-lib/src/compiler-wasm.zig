//! TODO: move this toanother place
//! ABI:
//! - stack
//! - For functions:
//!   - Each graphl parameter function is converted to a wasm parameter
//!     - primitives are passed by value
//!     - compound types are passed by reference
//!   - if the result is non-primitive/singleton, add a "return pointer" initial i32 parameter
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
// TODO: rename to graphl
const graphl_builtin = @import("./nodes/builtin.zig");
const empty_type = graphl_builtin.empty_type;
const primitive_types = @import("./nodes/builtin.zig").primitive_types;
const Env = @import("./nodes/builtin.zig").Env;
const TypeInfo = @import("./nodes/builtin.zig").TypeInfo;
const Type = @import("./nodes/builtin.zig").Type;
const builtin_nodes = @import("./nodes/builtin.zig").builtin_nodes;
const Pin = @import("./nodes/builtin.zig").Pin;
const pool = &@import("./InternPool.zig").pool;
const SymMapUnmanaged = @import("./InternPool.zig").SymMapUnmanaged;
pub const UserFunc = @import("./compiler-types.zig").UserFunc;

const t = std.testing;
const SexpParser = @import("./sexp_parser.zig").Parser;
const SpacePrint = @import("./sexp_parser.zig").SpacePrint;

const log = std.log.scoped(.graphlt_compiler);

const intrinsics_vec3 = @embedFile("graphl_intrinsics_vec3");
const intrinsics_string = @embedFile("graphl_intrinsics_string");

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
        // FIXME: rename to just "WrongArity", it's no longer used for just builtins
        BuiltinWrongArity: struct {
            callee: u32,
            expected: u16,
            received: u16,
        },
        DefineWithoutTypeOf: u32,
        InvalidIR,
        AccessNonCompound: struct {
            idx: u32,
            type: Type,
            field_name: []const u8,
        },
        AccessNonExistentField: struct {
            idx: u32,
            type: Type,
            field_name: []const u8,
        },
        StructTooLarge: struct {
            type: Type,
        },
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
        AccessNonCompound,
        AccessNonExistentField,
        StructTooLarge,
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
                // TODO: move this repeated thing to a function
                // FIXME: HACK
                const sexp = self.graphlt_module.get(sym_id);

                if (sexp.span == null or self.graphlt_module.source == null) {
                    try writer.print("Undefined symbol '{s}'", .{sexp.value.symbol});
                    return;
                }

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

                if (sexp.span == null or self.graphlt_module.source == null) {
                    try writer.print("Incorrect argument count for '{s}'", .{sexp.value.symbol});
                    return;
                }

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
            .AccessNonCompound => |err_info| {
                // FIXME: HACK
                const sexp = self.graphlt_module.get(err_info.idx);

                if (sexp.span == null or self.graphlt_module.source == null) {
                    try writer.print("Attempted to access field '{s}' of type '{s}' which doesn't support field access", .{
                        err_info.field_name,
                        err_info.type.name,
                    });
                    return;
                }

                const span = sexp.span.?;
                const byte_offset: usize = span.ptr - self.graphlt_module.source.?.ptr;

                var loc: Loc = .{};
                while (loc.index != byte_offset) {
                    loc.increment(self.graphlt_module.source.?);
                }

                try writer.print(
                    \\Attempted to access field '{s}' of type '{s}' which doesn't support field access
                    \\{}:
                    \\  | {s}
                    \\    {}^
                    \\
                , .{
                    err_info.field_name,
                    err_info.type.name,
                    loc,
                    try loc.containing_line(self.graphlt_module.source.?),
                    SpacePrint.init(loc.col - 1),
                });
            },
            .AccessNonExistentField => |err_info| {
                // FIXME: HACK
                const sexp = self.graphlt_module.get(err_info.idx);

                if (sexp.span == null or self.graphlt_module.source == null) {
                    try writer.print("Attempted to access field '{s}', but type '{s}' has no such field", .{
                        err_info.field_name,
                        err_info.type.name,
                    });
                    return;
                }

                const span = sexp.span.?;
                const byte_offset: usize = span.ptr - self.graphlt_module.source.?.ptr;

                var loc: Loc = .{};
                while (loc.index != byte_offset) {
                    loc.increment(self.graphlt_module.source.?);
                }

                try writer.print(
                    \\Attempted to access field '{s}', but type '{s}' has no such field
                    \\{}:
                    \\  | {s}
                    \\    {}^
                    \\
                , .{
                    err_info.field_name,
                    err_info.type.name,
                    loc,
                    try loc.containing_line(self.graphlt_module.source.?),
                    SpacePrint.init(loc.col - 1),
                });
            },
            .InvalidIR => {
                try writer.writeAll(
                    \\Compiler failed to generate valid binaryen IR, see stderr for details.
                    \\
                );
            },
            .StructTooLarge => |info| {
                try writer.print(
                    \\Struct type '{s}' too large, go report this as a bug
                    \\
                , .{info.type.name});
            },
            inline else => |idx, tag| {
                // FIXME: HACK
                const sexp = self.graphlt_module.get(idx);

                if (sexp.span == null or self.graphlt_module.source == null) {
                    try writer.print("{s}: '{s}'", .{ @tagName(tag), sexp.value.symbol });
                    return;
                }


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
    define_body_idx: u32,
};

const DeferredFuncTypeInfo = struct {
    param_types: []const Type,
    result_types: []const Type,
    result_names: []const [:0]const u8,
};

var empty_user_funcs = std.SinglyLinkedList(UserFunc){};

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
    var heap_type_map: std.AutoHashMapUnmanaged(Type, byn.c.BinaryenHeapType) = .{};

    /// whether this type can be put in a local in wasm
    pub fn isValueType(graphl_type: Type) bool {
        return graphl_type == empty_type //
        or graphl_type == primitive_types.i32_ //
        or graphl_type == primitive_types.i64_ //
        or graphl_type == primitive_types.u32_ //
        or graphl_type == primitive_types.u64_ //
        or graphl_type == primitive_types.f32_ //
        or graphl_type == primitive_types.f64_ //
        or graphl_type == primitive_types.byte //
        or graphl_type == primitive_types.bool_ //
        or graphl_type == primitive_types.char_ //
        or graphl_type == primitive_types.symbol //
        or graphl_type == primitive_types.rgba //
        ;
    }

    pub fn getHeapType(graphl_type: Type, features: *Features) byn.c.BinaryenHeapType {
        // FIXME: gross, figure out a better way to make this distinction, maybe above isValueType?
        if (graphl_type == primitive_types.string) {
            // FIXME: cache this specific one?
            return heap_type_map.get(graphl_type) orelse unreachable;
        }

        std.debug.assert(graphl_type.subtype == .@"struct");

        const graphl_struct_info = graphl_type.subtype.@"struct";
        const entry = heap_type_map.getOrPut(alloc.allocator(), graphl_type) catch unreachable;

        if (entry.found_existing) {
            return entry.value_ptr.*;
        }

        const tb: byn.c.TypeBuilderRef = byn.c.TypeBuilderCreate(1);

        const byn_types = alloc.allocator().alloc(byn.c.BinaryenType, graphl_struct_info.field_types.len) catch unreachable;
        for (graphl_struct_info.field_types, byn_types) |field_type, *byn_type| {
            byn_type.* = getType(field_type, features);
        }

        const is_packed = alloc.allocator().alloc(byn.c.BinaryenPackedType, graphl_struct_info.field_types.len) catch unreachable;
        for (is_packed) |*p| p.* = byn.c.BinaryenPackedTypeNotPacked();

        const is_mut = alloc.allocator().alloc(bool, graphl_struct_info.field_types.len) catch unreachable;
        for (is_mut) |*m| m.* = true;

        byn.c.TypeBuilderSetStructType(
            tb,
            0,
            byn_types.ptr,
            is_packed.ptr,
            is_mut.ptr,
            @intCast(graphl_struct_info.field_types.len),
        );

        var built_heap_types: [1]byn.c.BinaryenHeapType = undefined;
        std.debug.assert(byn.c.TypeBuilderBuildAndDispose(tb, &built_heap_types, null, null));

        const byn_heap_type = built_heap_types[0];
        std.debug.assert(byn.c.BinaryenHeapTypeIsStruct(byn_heap_type));

        entry.value_ptr.* = byn_heap_type;

        const byn_type = byn.c.BinaryenTypeFromHeapType(byn_heap_type, false);
        BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), graphl_type, byn_type) catch unreachable;

        return byn_heap_type;
    }

    pub fn getType(graphl_type: Type, features: *Features) byn.c.BinaryenType {
        if (graphl_type.subtype == .@"struct")
            _ = getHeapType(graphl_type, features); // careful of recursion

        // TODO: use switch if compiler supports it
        if (graphl_type == primitive_types.string and !features.string) {
            // TODO: don't add string type until we hit this?
            features.string = true;
        } else if (graphl_type == primitive_types.vec3 and !features.vec3) {
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
    const tb: byn.c.TypeBuilderRef = byn.c.TypeBuilderCreate(1);
    byn.c.TypeBuilderSetArrayType(tb, 0, byn.c.BinaryenTypeInt32(), byn.c.BinaryenPackedTypeInt8(), 1);

    var built_heap_types: [1]byn.c.BinaryenHeapType = undefined;
    std.debug.assert(byn.c.TypeBuilderBuildAndDispose(tb, &built_heap_types, 0, 0));
    const i8_array_heap = built_heap_types[0];
    const i8_array = byn.c.BinaryenTypeFromHeapType(i8_array_heap, false);

    // TODO: do what hoot does and compile to stringref but downpass it to i8-array
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.code, i8_array) catch unreachable;
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.symbol, i8_array) catch unreachable;
    // FIXME: lazily add this type if a string is used!
    BinaryenHelper.type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.string, i8_array) catch unreachable;

    BinaryenHelper.heap_type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.code, i8_array_heap) catch unreachable;
    BinaryenHelper.heap_type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.symbol, i8_array_heap) catch unreachable;
    // FIXME: symbols should not be an i8-array... there should be a symbol store but it should be an int!
    BinaryenHelper.heap_type_map.putNoClobber(BinaryenHelper.alloc.allocator(), primitive_types.string, i8_array_heap) catch unreachable;
}

// FIXME: idk if this works in wasm, maybe do it in tests only?
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
    _sexp_compiled: []Slot,

    // FIXME: figure out how segments works cuz I haven't figured it out yet
    ro_data_offset: u32 = mem_start + str_transfer_seg_size,

    module: *byn.Module,
    arena: std.heap.ArenaAllocator,
    user_context: struct {
        funcs: *const std.SinglyLinkedList(UserFunc),
        func_map: std.StringHashMapUnmanaged(*UserFunc),
    },

    used_features: Features = .{},
    file_byn_index: byn.c.BinaryenIndex,

    type_intrinsics_generated: std.AutoHashMapUnmanaged(byn.c.BinaryenType, void) = .{},

    // FIXME: support multiple diagnostics
    diag: *Diagnostic,

    // according to binaryen docs, there are optimizations if you
    // do not use the first 1Kb
    pub const mem_start = 1024;

    pub const transfer_seg_start = mem_start;

    // TODO: rename to general transfer buffer
    pub const str_transfer_seg_size = 4096;

    pub const Slot = struct {
        // FIXME: remove? doing heap structs for now
        // FIXME: should this have a pointer to its frame?
        /// how far into its frame the data for this item starts (if it is a primitive)
        frame_depth: u32 = 0,
        /// index of the local holding this data in its function
        local_index: byn.c.BinaryenIndex,
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
    pub const stack_ptr_name = "__gstkp";

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
            .file_byn_index = undefined,
        };

        byn.c.BinaryenSetDebugInfo(true);

        result.file_byn_index = byn.c.BinaryenModuleAddDebugInfoFileName(result.module.c(), "file-name-not-supported-fixme");
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
                byn.Features.BulkMemory(), // FIXME: is this enabled on safari?
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

        std.debug.assert(byn.c.BinaryenAddGlobal(
            result.module.c(),
            stack_ptr_name,
            byn.c.BinaryenTypeInt32(),
            true,
            // FIXME: note that the ro_data_offset is currently this same number, but since those are data segments
            // I think it's actually fine... need to double check though
            byn.c.BinaryenConst(result.module.c(), byn.c.BinaryenLiteralInt32(@intCast(mem_start + str_transfer_seg_size))),
        ) != null);

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
            .define_body_idx = sexp_index,
        };

        try self.deferred.func_decls.put(alloc, func_name, func_desc);

        if (self.deferred.func_types.get(func_name)) |func_type| {
            try self.finishCompileTypedFunc(func_name, func_desc, func_type);
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

    // FIXME: this will crash obscenely large result types lol
    const result_names_cached = [_][:0]const u8{
        "0",  "1",  "2",  "3",  "4",  "5",  "6",  "7",  "8",  "9",  "10", "11", "12",
        //
        "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23", "24",
    };

    /// e.g. (typeof (foo i32) i32))
    /// e.g. (typeof (bar i32) (i32 string))
    fn compileTypeOfFunc(self: *@This(), sexp: *const Sexp) !bool {
        const alloc = self.arena.allocator();

        const func_name = sexp.getWithModule(1, self.graphlt_module).getWithModule(0, self.graphlt_module).value.symbol;
        const param_type_expr_idxs = sexp.getWithModule(1, self.graphlt_module).value.list.items[1..];

        const result_types_expr = sexp.getWithModule(2, self.graphlt_module);

        var result_names: []const [:0]const u8 = undefined;
        var result_types: []Type = undefined;
        // FIXME: types must be symbols (for now)
        switch (result_types_expr.value) {
            .symbol => |sym| {
                result_types = try alloc.alloc(Type, 1);
                result_types[0] = self.env.getType(sym) orelse return error.UnknownType;
                result_names = result_names_cached[0..1];
            },
            .list => |list| {
                result_types = try alloc.alloc(Type, list.items.len);
                for (result_types, list.items) |*result_type, sexp_idx| {
                    const result_type_sexp = self.graphlt_module.get(sexp_idx);
                    if (result_type_sexp.value != .symbol) {
                        return error.FuncTypeDeclMultiResultEntryNotSymbol;
                    }
                    result_type.* = self.env.getType(result_type_sexp.value.symbol) orelse return error.UnknownType;
                }
                result_names = result_names_cached[0..list.items.len];
            },
            else => return error.FuncTypeDeclResultNotSymbolOrList,
        }
        errdefer alloc.free(result_types);

        const param_types = try alloc.alloc(Type, param_type_expr_idxs.len);
        errdefer alloc.free(param_types);
        for (param_type_expr_idxs, param_types) |type_expr_idx, *type_| {
            const type_expr = self.graphlt_module.get(type_expr_idx);
            const param_type = type_expr.value.symbol;
            type_.* = self.env.getType(param_type) orelse return error.UnknownType;
        }

        const func_type_desc = DeferredFuncTypeInfo{
            .param_types = param_types,
            .result_types = result_types,
            .result_names = result_names,
        };

        try self.deferred.func_types.put(alloc, func_name, func_type_desc);

        if (self.deferred.func_decls.getPtr(func_name)) |func_decl| {
            try self.finishCompileTypedFunc(func_name, func_decl.*, func_type_desc);
        }

        return true;
    }

    fn finishCompileTypedFunc(self: *@This(), name: [:0]const u8, func_decl: DeferredFuncDeclInfo, func_type: DeferredFuncTypeInfo) !void {
        // NOTE: technically we can free the deferred function infos after this function

        // TODO: configure std.log.debug
        //std.log.debug("compile func: '{s}'\n", .{name});
        // now that we have func
        const node_desc = _: {
            const slot = try self.arena.allocator().create(graphl_builtin.BasicMutNodeDesc);
            slot.* = .{
                .name = name,
                .kind = .func,
                // FIXME: can I reuse pins?
                .inputs = try self.arena.allocator().alloc(Pin, func_type.param_types.len + 1),
                .outputs = try self.arena.allocator().alloc(Pin, func_type.result_types.len + 1),
            };
            slot.inputs[0] = Pin{ .name = "in", .kind = .{ .primitive = .exec } };
            for (slot.inputs[1..], func_decl.param_names, func_type.param_types) |*pin, pn, pt| {
                pin.* = Pin{ .name = pn, .kind = .{ .primitive = .{ .value = pt } } };
            }
            slot.outputs[0] = Pin{ .name = "out", .kind = .{ .primitive = .exec } };
            for (slot.outputs[1..], func_type.result_types) |*pin, rt| {
                pin.* = Pin{ .name = "FIXME", .kind = .{ .primitive = .{ .value = rt } } };
            }
            // we must use the same allocator that env is deinited with!
            break :_ try self.env.addNode(self.arena.child_allocator, graphl_builtin.basicMutableNode(slot));
        };

        const result_types = try self.arena.allocator().alloc(byn.c.BinaryenType, func_type.result_types.len);
        defer self.arena.allocator().free(result_types); // FIXME: what is the binaryen ownership model?
        for (result_types, func_type.result_types) |*wasm_t, graphl_t| {
            wasm_t.* = try self.getBynType(graphl_t);
        }

        const ResultType = struct {
            byn: byn.c.BinaryenType,
            graphl: Type,
        };

        // FIXME: don't make a tuple type if there's only 1!
        const result_type: ResultType = _: {
            if (func_type.result_types.len == 0) {
                break :_ .{
                    .byn = byn.c.BinaryenTypeNone(),
                    .graphl = primitive_types.void,
                };
            } else if (func_type.result_types.len == 1) {
                break :_ .{
                    .byn = try self.getBynType(func_type.result_types[0]),
                    .graphl = func_type.result_types[0],
                };
            } else {
                // FIXME: separate function and whole module arenas
                const graphl_type_slot = try self.arena.allocator().create(TypeInfo);
                graphl_type_slot.* = .{
                    .name = name,
                    .size = 0,
                    .subtype = .{ .@"struct" = try .initFromTypeList(self.arena.allocator(), .{
                        .field_types = func_type.result_types,
                        .field_names = func_type.result_names,
                    }) },
                };
                break :_ .{
                    .byn = try self.getBynType(graphl_type_slot),
                    .graphl = graphl_type_slot,
                };
            }
        };

        // FIXME: rename
        // TODO: use @FieldType
        var locals_symbols: SymMapUnmanaged(FnContext.LocalInfo) = .{};
        defer locals_symbols.deinit(self.arena.allocator());

        for (func_decl.param_names, func_decl.param_name_idxs, func_type.param_types) |p_name, p_idx, p_type| {
            const index: u32 = @intCast(locals_symbols.count());
            const put_res = try locals_symbols.getOrPut(self.arena.allocator(), p_name);

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

        // add the return pointer param as first one if not returning a primitive
        const param_count: u16 = @intCast(func_type.param_types.len);

        const param_types = try self.arena.allocator().alloc(byn.c.BinaryenType, param_count);
        defer self.arena.allocator().free(param_types); // FIXME: what is the binaryen ownership model
        for (param_types, func_type.param_types) |*wasm_t, graphl_t| {
            wasm_t.* = try self.getBynType(graphl_t);
        }
        const param_type_byn = byn.c.BinaryenTypeCreate(param_types.ptr, @intCast(param_types.len));

        var fn_ctx = FnContext{
            .local_symbols = &locals_symbols,
            .local_types = &byn_locals_types,
            .param_count = param_count,
            // locals should be placed after params
            .next_sexp_local_idx = param_count,
            .relooper = byn.c.RelooperCreate(self.module.c()) orelse @panic("relooper creation failed"),
            .return_type = result_type.graphl,
            .func_type = node_desc,
        };

        try self.compileExpr(func_decl.define_body_idx, &fn_ctx);

        // set up the stack frame
        const func_prologue = byn.c.RelooperAddBlock(
            fn_ctx.relooper,
            if (fn_ctx._frame_byte_size == 0)
                byn.c.BinaryenNop(self.module.c())
            else
                byn.c.BinaryenGlobalSet(
                    self.module.c(),
                    stack_ptr_name,
                    byn.c.BinaryenBinary(
                        self.module.c(),
                        byn.c.BinaryenAddInt32(),
                        byn.c.BinaryenGlobalGet(self.module.c(), stack_ptr_name, byn.c.BinaryenTypeInt32()),
                        byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@intCast(fn_ctx._frame_byte_size))),
                    ),
                ),
        );
        const func_body = &self._sexp_compiled[func_decl.define_body_idx];
        // tear down the stack frame
        const func_epilogue = byn.c.RelooperAddBlock(
            fn_ctx.relooper,
            if (fn_ctx._frame_byte_size == 0)
                byn.c.BinaryenNop(self.module.c())
            else
                byn.c.BinaryenGlobalSet(
                    self.module.c(),
                    stack_ptr_name,
                    byn.c.BinaryenBinary(
                        self.module.c(),
                        // would storing it as a local be better?
                        byn.c.BinaryenSubInt32(),
                        byn.c.BinaryenGlobalGet(self.module.c(), stack_ptr_name, byn.c.BinaryenTypeInt32()),
                        byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@intCast(fn_ctx._frame_byte_size))),
                    ),
                ),
        );

        try self.linkExpr(
            func_decl.define_body_idx,
            &fn_ctx,
            &.{ .epilogue = func_epilogue },
        );

        byn.c.RelooperAddBranch(func_prologue, func_body.pre_block, null, null);

        const body = byn.c.RelooperRenderAndDispose(
            fn_ctx.relooper,
            func_prologue,
            0,
        );

        // NOTE: not sure why but branching from the define_body_idx/post to unreachable doesn't
        // seem to work, so building a block manually
        const body_with_end = byn.c.BinaryenBlock(
            self.module.c(),
            null,
            // TODO: move this constCast
            @constCast(&[_]byn.c.BinaryenExpressionRef{
                body,
                if (result_type.graphl == primitive_types.void)
                    byn.c.BinaryenNop(self.module.c())
                else
                    byn.c.BinaryenUnreachable(self.module.c()),
            }),
            2,
            byn.c.BinaryenTypeUnreachable(),
        );

        const byn_local_types = try self.arena.allocator().alloc(byn.Type, byn_locals_types.items.len);
        defer self.arena.allocator().free(byn_local_types);
        for (byn_local_types, byn_locals_types.items) |*byn_local_type, local_type| {
            byn_local_type.* =
                // FIXME: don't store locals for empties
                if (local_type == graphl_builtin.empty_type)
                    byn.Type.i32
                else
                    @enumFromInt(try self.getBynType(local_type));
        }

        const func = self.module.addFunction(
            name,
            @enumFromInt(param_type_byn),
            @enumFromInt(result_type.byn),
            byn_local_types,
            @ptrCast(body_with_end),
        );

        std.debug.assert(func != null);

        const export_ref = byn.c.BinaryenAddFunctionExport(self.module.c(), name, name);
        std.debug.assert(export_ref != null);
    }

    inline fn getBynType(self: *@This(), graphl_type: Type) (Diagnostic.Code || std.mem.Allocator.Error)!byn.c.BinaryenType {
        const byn_type = BinaryenHelper.getType(graphl_type, &self.used_features);

        const has_intrinsics = (try self.type_intrinsics_generated.getOrPut(self.arena.allocator(), byn_type)).found_existing;
        if (graphl_type.subtype == .@"struct" and !has_intrinsics) {
            _ = try self.addCopyIntrinsicFuncForHeapStruct(graphl_type, byn_type);
        }
        return byn_type;
    }

    inline fn getBynHeapType(self: *@This(), graphl_type: Type) (Diagnostic.Code || std.mem.Allocator.Error)!byn.c.BinaryenHeapType {
        // FIXME: technically do this, maybe assert that it's in self.type_intrinsics_generated
        // _ = self.getBynType(graphl_type);
        const byn_heap_type = BinaryenHelper.getHeapType(graphl_type, &self.used_features);
        return byn_heap_type;
    }

    const HeapStructCopyFuncs = struct {
        write_fields: byn.c.BinaryenFunctionRef,
        write_array: byn.c.BinaryenFunctionRef,
        read_fields: byn.c.BinaryenFunctionRef,
    };

    fn addCopyIntrinsicFuncForHeapStruct(
        self: *@This(),
        graphl_type: Type,
        struct_byn_type: byn.c.BinaryenType,
    ) (Diagnostic.Code || std.mem.Allocator.Error)!HeapStructCopyFuncs {
        const struct_byn_heap_type = try self.getBynHeapType(graphl_type);

        if (graphl_type.size > str_transfer_seg_size) {
            self.diag.err = .{ .StructTooLarge = .{ .type = graphl_type } };
            return error.StructTooLarge;
        }

        const prim_field_count = graphl_type.subtype.@"struct".flat_primitive_slot_count;
        const array_field_count = graphl_type.subtype.@"struct".flat_array_count;

        const write_fields = _: {
            const vars = struct {
                pub const param_struct_ref = 0;
            };

            const prologue = [_]byn.c.BinaryenExpressionRef{};

            const epilogue = [_]byn.c.BinaryenExpressionRef{
                byn.c.BinaryenReturn(
                    self.module.c(),
                    // FIXME: implement
                    byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@intCast(array_field_count))),
                ),
            };

            const impl = try self.arena.allocator().alloc(
                byn.c.BinaryenExpressionRef,
                prologue.len + graphl_type.subtype.@"struct".flat_primitive_slot_count + epilogue.len,
            );

            @memcpy(impl[0..prologue.len], prologue[0..]);
            @memcpy(impl[prologue.len + prim_field_count ..], epilogue[0..]);

            // FIXME: support nested structs
            {
                var field_iter_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer field_iter_arena.deinit();
                var field_iter = graphl_type.recursiveSubfieldIterator(field_iter_arena.allocator());

                var i: u32 = 0;
                for (
                    impl[prologue.len .. prologue.len + prim_field_count],
                ) |*field_expr| {
                    const field_info = field_iter.next() orelse unreachable;
                    // FIXME: add like BinaryenHelper.isHeapType
                    if (field_info.type == primitive_types.string) continue;

                    const field_byn_type = try self.getBynType(field_info.type);
                    field_expr.* = byn.c.BinaryenStore(
                        self.module.c(),
                        field_info.type.size,
                        0,
                        4, // FIXME: store alignment on type?
                        @ptrCast(byn.Expression.binaryOp(
                            self.module,
                            byn.Expression.Op.addInt32(),
                            @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(transfer_seg_start))),
                            @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@bitCast(field_info.offset)))),
                        )),
                        byn.c.BinaryenStructGet(
                            self.module.c(),
                            i,
                            byn.c.BinaryenLocalGet(self.module.c(), vars.param_struct_ref, struct_byn_type),
                            field_byn_type,
                            false,
                        ),
                        @intFromEnum(byn.Type.i32),
                        main_mem_name,
                    );
                    i += 1;
                }
            }

            const name = try std.fmt.allocPrint(self.arena.allocator(), "__graphl_write_struct_{s}_fields", .{graphl_type.name});

            const func = byn.c.BinaryenAddFunction(
                self.module.c(),
                name.ptr,
                byn.c.BinaryenTypeCreate(@constCast(&[_]byn.c.BinaryenType{
                    struct_byn_type, // struct ref
                }).ptr, 1),
                byn.c.BinaryenTypeInt32(), // returns array count
                null,
                0,
                byn.c.BinaryenBlock(
                    self.module.c(),
                    null,
                    impl.ptr,
                    @intCast(impl.len),
                    byn.c.BinaryenTypeNone(),
                ),
            );

            std.debug.assert(byn.c.BinaryenAddFunctionExport(self.module.c(), name.ptr, name.ptr) != null);

            break :_ func;
        };

        const write_array = _: {
            const vars = struct {
                pub const param_struct_ref = 0;
                pub const param_array_slot_idx = 1;
                pub const param_array_read_offset = 2;
            };

            var impl = try std.ArrayListUnmanaged(byn.c.BinaryenExpressionRef).initCapacity(self.arena.allocator(), graphl_type.subtype.@"struct".flat_array_count + 1);
            //defer impl.de

            // FIXME: support nested structs
            {
                var field_iter_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer field_iter_arena.deinit();
                var field_iter = graphl_type.recursiveSubfieldIterator(field_iter_arena.allocator());

                var array_slot_index: u32 = 0;
                var field_index: u32 = 0;
                while (field_iter.next()) |field_info| : (field_index += 1) {
                    // FIXME: add like BinaryenHelper.isHeapType
                    if (field_info.type != primitive_types.string) continue;

                    const field_byn_type = try self.getBynType(field_info.type);
                    impl.appendAssumeCapacity(byn.c.BinaryenIf(
                        self.module.c(),
                        byn.c.BinaryenBinary(
                            self.module.c(),
                            byn.c.BinaryenEqInt32(),
                            byn.c.BinaryenLocalGet(self.module.c(), vars.param_array_slot_idx, byn.c.BinaryenTypeInt32()),
                            byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@bitCast(array_slot_index))),
                        ),
                        byn.c.BinaryenReturn(
                            self.module.c(),
                            byn.c.BinaryenCall(
                                self.module.c(),
                                "__graphl_host_copy",
                                @constCast(&[_]byn.c.BinaryenExpressionRef{
                                    byn.c.BinaryenStructGet(
                                        self.module.c(),
                                        field_index,
                                        byn.c.BinaryenLocalGet(self.module.c(), vars.param_struct_ref, struct_byn_type),
                                        field_byn_type,
                                        false,
                                    ),
                                    byn.c.BinaryenLocalGet(self.module.c(), vars.param_array_read_offset, byn.c.BinaryenTypeInt32()),
                                }),
                                2,
                                @intFromEnum(byn.Type.i32),
                            ),
                        ),
                        null,
                    ));

                    array_slot_index += 1;
                }
            }

            impl.appendAssumeCapacity(byn.c.BinaryenUnreachable(self.module.c()));

            // FIXME: use a buf, pretty sure binaryen just copies this, no point bloating the arena
            const name = try std.fmt.allocPrint(self.arena.allocator(), "__graphl_write_struct_{s}_array", .{graphl_type.name});

            const func = byn.c.BinaryenAddFunction(
                self.module.c(),
                name.ptr,
                byn.c.BinaryenTypeCreate(@constCast(&[_]byn.c.BinaryenType{
                    struct_byn_type, // struct ref
                    byn.c.BinaryenTypeInt32(), // array slot index
                    byn.c.BinaryenTypeInt32(), // offset in array
                }).ptr, 3),
                byn.c.BinaryenTypeInt32(), // returns bytes written count
                null,
                0,
                byn.c.BinaryenBlock(
                    self.module.c(),
                    null,
                    impl.items.ptr,
                    @intCast(impl.items.len),
                    byn.c.BinaryenTypeNone(),
                ),
            );

            std.debug.assert(byn.c.BinaryenAddFunctionExport(self.module.c(), name.ptr, name.ptr) != null);

            break :_ func;
        };

        // allocate a new struct and initialize it from pointed-to memory
        const read_fields = _: {
            // const vars = struct {
            //     pub const param_base_ptr = 0;
            // };

            const operands = try self.arena.allocator().alloc(
                byn.c.BinaryenExpressionRef,
                graphl_type.subtype.@"struct".flat_primitive_slot_count + graphl_type.subtype.@"struct".flat_array_count,
            );

            // FIXME: run this loop once and construct both functions at once?
            // FIXME: support nested structs
            {
                var field_iter_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer field_iter_arena.deinit();
                var field_iter = graphl_type.recursiveSubfieldIterator(field_iter_arena.allocator());

                // FIXME: this doesn't support structs with heap references inside them!
                for (operands) |*operand| {
                    const field_info = field_iter.next() orelse unreachable;
                    const field_byn_type = try self.getBynType(field_info.type);

                    operand.* = if (field_info.type == primitive_types.string)
                        byn.c.BinaryenArrayNew(
                            self.module.c(),
                            try self.getBynHeapType(primitive_types.string),
                            byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(0)),
                            byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(0)),
                        )
                    else
                        byn.c.BinaryenLoad(
                            self.module.c(),
                            field_info.type.size,
                            false,
                            0,
                            4, // FIXME: store alignment on type
                            field_byn_type,
                            byn.c.BinaryenBinary(
                                self.module.c(),
                                byn.c.BinaryenAddInt32(),
                                byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(transfer_seg_start)),
                                byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@bitCast(field_info.offset))),
                            ),
                            main_mem_name,
                        );
                }
            }

            const name = try std.fmt.allocPrint(self.arena.allocator(), "__graphl_read_struct_{s}_fields", .{graphl_type.name});

            const func = byn.c.BinaryenAddFunction(
                self.module.c(),
                name.ptr,
                byn.c.BinaryenTypeCreate(@constCast(&[_]byn.c.BinaryenType{}).ptr, 0),
                struct_byn_type, // returns read struct
                null,
                0,
                // byn.c.BinaryenBlock(
                //     self.module.c(),
                //     null,
                //     impl.ptr,
                //     @intCast(impl.len),
                //     byn.c.BinaryenTypeNone(),
                // ),
                byn.c.BinaryenReturn(
                    self.module.c(),
                    byn.c.BinaryenStructNew(self.module.c(), operands.ptr, @intCast(operands.len), struct_byn_heap_type),
                ),
            );

            std.debug.assert(byn.c.BinaryenAddFunctionExport(self.module.c(), name.ptr, name.ptr) != null);

            break :_ func;
        };

        return .{
            .write_fields = write_fields,
            .write_array = write_array,
            .read_fields = read_fields,
        };
    }

    fn compileExpr(
        self: *@This(),
        code_sexp_idx: u32,
        /// not const because we may be expanding the frame to include this value
        fn_ctx: *FnContext,
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
                        // FIXME: leave type unresolved
                        slot.type = graphl_builtin.empty_type;
                        try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                        slot.expr = byn.c.BinaryenNop(self.module.c());

                        if (v.items.len != 3) {
                            self.diag.err = .{ .BuiltinWrongArity = .{
                                .callee = v.items[0],
                                .expected = 2,
                                .received = @intCast(v.items.len - 1),
                            } };
                            return error.BuiltinWrongArity;
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
                        const return_types = if (fn_ctx.return_type.subtype == .@"struct")
                            fn_ctx.return_type.subtype.@"struct".field_types
                        else
                            &.{fn_ctx.return_type};

                        if (return_types.len != v.items[1..].len) {
                            self.diag.err = .{ .BuiltinWrongArity = .{
                                .callee = v.items[0],
                                .expected = 2,
                                .received = @intCast(v.items.len - 1),
                            } };
                            return error.BuiltinWrongArity;
                        }

                        for (v.items[1..], return_types) |arg, return_type| {
                            try self.compileExpr(arg, fn_ctx);
                            self.promoteToTypeInPlace(&self._sexp_compiled[arg], return_type);
                        }

                        if (v.items.len == 1) {
                            slot.type = primitive_types.void;
                            try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                            slot.expr = byn.c.BinaryenReturn(self.module.c(), byn.c.BinaryenNop(self.module.c()));
                            //
                        } else if (v.items.len == 2) {
                            const first_arg = &self._sexp_compiled[v.items[1]];
                            slot.type = first_arg.type;
                            try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                            slot.expr = byn.c.BinaryenReturn(
                                self.module.c(),
                                byn.c.BinaryenLocalGet(self.module.c(), first_arg.local_index, try self.getBynType(first_arg.type)),
                            );
                            //
                        } else if (v.items.len > 2) {
                            slot.type = fn_ctx.return_type;
                            try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);

                            const return_struct_info = fn_ctx.return_type.subtype.@"struct";
                            var operands = try std.ArrayListUnmanaged(byn.c.BinaryenExpressionRef).initCapacity(self.arena.allocator(), return_struct_info.field_names.len + 1);
                            //defer operands.deinit(self.arena.allocator());

                            for (return_struct_info.field_types, v.items[1..]) |field_type, ctor_arg_idx| {
                                const ctor_arg = &self._sexp_compiled[ctor_arg_idx];
                                // FIXME: handle all array types
                                _ = field_type; // FIXME
                                operands.appendAssumeCapacity(byn.c.BinaryenLocalGet(
                                    self.module.c(),
                                    ctor_arg.local_index,
                                    try self.getBynType(ctor_arg.type),
                                ));
                            }

                            slot.expr = byn.c.BinaryenReturn(self.module.c(), byn.c.BinaryenStructNew(
                                self.module.c(),
                                operands.items.ptr,
                                @intCast(operands.items.len),
                                try self.getBynHeapType(fn_ctx.return_type),
                            ));
                        }

                        // FIXME: construct return tuple type from all arguments

                        break :done;
                    }

                    if (func.value.symbol.ptr == syms.begin.value.symbol.ptr) {
                        for (v.items[1..]) |arg| {
                            try self.compileExpr(arg, fn_ctx);
                        }

                        slot.type = graphl_builtin.empty_type;

                        if (v.items.len >= 2) {
                            const last_arg_idx = v.items[v.items.len - 1];
                            // FIXME: check the ExprContext and maybe promote the type...
                            slot.type = self._sexp_compiled[last_arg_idx].type;
                        }

                        try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                        slot.expr = byn.c.BinaryenNop(self.module.c());

                        break :done;
                    }

                    if (func.value.symbol.ptr == syms.define.value.symbol.ptr) {
                        const binding = self.graphlt_module.get(v.items[1]);

                        // no need to compile bindings, they aren't valid expressions
                        // FIXME: add bindings to env
                        for (v.items[2..]) |arg| {
                            try self.compileExpr(arg, fn_ctx);
                        }

                        switch (binding.value) {
                            // function def
                            .list => {
                                slot.type = fn_ctx.return_type;
                                try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                                slot.expr = byn.c.BinaryenNop(self.module.c());
                                break :done;
                            },
                            // variable def
                            .symbol => |sym| {
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
                                // FIXME: check the typeof (via env?) and promote the type...
                                slot.type = local_symbol.type;
                                try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);

                                if (v.items.len == 3) {
                                    // has default to set
                                    slot.expr = byn.c.BinaryenLocalSet(
                                        self.module.c(),
                                        local_index,
                                        self.promoteToType(
                                            last_arg_slot.type,
                                            byn.c.BinaryenLocalGet(
                                                self.module.c(),
                                                last_arg_slot.local_index,
                                                try self.getBynType(last_arg_slot.type),
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
                                    return error.BuiltinWrongArity;
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

                    // TODO: parse these as a separate node type?
                    const is_field_access = std.mem.startsWith(u8, func.value.symbol, ".") and func.value.symbol.len > 1;
                    if (is_field_access) {
                        const field_name = pool.getSymbol(func.value.symbol[1..]);

                        if (v.items.len != 2) {
                            self.diag.err = .{ .BuiltinWrongArity = .{
                                .callee = v.items[0],
                                .expected = 1,
                                .received = @intCast(v.items.len - 1),
                            } };
                            return error.BuiltinWrongArity;
                        }

                        try self.compileExpr(v.items[1], fn_ctx);
                        const arg = &self._sexp_compiled[v.items[1]];

                        if (arg.type.subtype != .@"struct") {
                            self.diag.err = .{ .AccessNonCompound = .{
                                .idx = v.items[0],
                                .type = arg.type,
                                .field_name = field_name,
                            } };
                            return error.AccessNonCompound;
                        }

                        const struct_info = arg.type.subtype.@"struct";

                        const field_index = _: {
                            for (struct_info.field_names, 0..) |s_field_name, i| {
                                if (field_name.ptr == s_field_name.ptr) {
                                    break :_ i;
                                }
                            }

                            self.diag.err = .{ .AccessNonExistentField = .{
                                .idx = v.items[0],
                                .type = arg.type,
                                .field_name = field_name,
                            } };
                            return error.AccessNonExistentField;
                        };

                        const field_type = struct_info.field_types[field_index];
                        const field_offset = struct_info.field_offsets[field_index];

                        slot.type = field_type;
                        try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);

                        const struct_ptr = byn.c.BinaryenLocalGet(
                            self.module.c(),
                            arg.local_index,
                            byn.c.BinaryenTypeInt32(),
                        );

                        const field_ptr = byn.c.BinaryenBinary(
                            self.module.c(),
                            byn.c.BinaryenAddInt32(),
                            struct_ptr,
                            // FIXME: use bitCast for LiteralInt32 taking a u32
                            byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@bitCast(field_offset))),
                        );

                        // FIXME: add a loadType helper
                        const field_value = if (BinaryenHelper.isValueType(slot.type))
                            byn.c.BinaryenLoad(
                                self.module.c(),
                                field_type.size,
                                false,
                                0,
                                4,
                                try self.getBynType(slot.type),
                                field_ptr,
                                main_mem_name,
                            )
                        else
                            field_ptr;

                        slot.expr = byn.c.BinaryenLocalSet(
                            self.module.c(),
                            local_index,
                            field_value,
                        );
                        break :done;
                    }

                    // call host functions
                    const func_node_desc = self.env.getNode(func.value.symbol) orelse {
                        log.err("while in:\n{}\n", .{Sexp.withContext(self.graphlt_module, code_sexp_idx)});
                        log.err("undefined symbol1: '{s}'\n", .{func.value.symbol});
                        self.diag.err = .{ .UndefinedSymbol = v.items[0] };
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

                        try self.compileExpr(arg_idx, fn_ctx);
                        const arg_compiled = &self._sexp_compiled[arg_idx];
                        args_top_type = resolvePeerType(args_top_type, arg_compiled.type);
                    }

                    if (func.value.symbol.ptr == syms.@"if".value.symbol.ptr) {
                        slot.type = args_top_type;
                        try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
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
                        try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                        slot.expr = byn.c.BinaryenLocalSet(
                            self.module.c(),
                            local_info.index orelse unreachable,
                            // FIXME: promote value?
                            byn.c.BinaryenLocalGet(self.module.c(), value_to_set.local_index, try self.getBynType(value_to_set.type)),
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

                            if (@hasField(@TypeOf(builtin_op), "result_type")) {
                                slot.type = builtin_op.result_type;
                            } else {
                                slot.type = args_top_type;
                            }
                            try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);

                            slot.expr = byn.c.BinaryenLocalSet(
                                self.module.c(),
                                local_index,
                                byn.c.BinaryenBinary(
                                    self.module.c(),
                                    op.c(),
                                    self.promoteToType(
                                        lhs.type,
                                        byn.c.BinaryenLocalGet(self.module.c(), lhs.local_index, try self.getBynType(lhs.type)),
                                        args_top_type,
                                    ),
                                    self.promoteToType(
                                        rhs.type,
                                        byn.c.BinaryenLocalGet(self.module.c(), rhs.local_index, try self.getBynType(rhs.type)),
                                        args_top_type,
                                    ),
                                ),
                            );

                            // REPORT ME: try to prefer an else on the above for loop, currently couldn't get it to compile right
                            if (!handled) {
                                log.err("unimplemented type resolution: '{s}' for code:\n{}\n", .{ slot.type.name, code_sexp });
                                std.debug.panic("unimplemented type resolution: '{s}'", .{slot.type.name});
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
                        const rawOuts = func_node_desc.getOutputs();

                        const is_pure = rawOuts.len == 1 and rawOuts[0].kind == .primitive and rawOuts[0].kind.primitive == .value;
                        const is_simple_0_out_impure = rawOuts.len == 1 and rawOuts[0].kind == .primitive and rawOuts[0].kind.primitive == .exec;
                        const is_simple_1_out_impure = rawOuts.len == 2 and rawOuts[0].kind == .primitive and rawOuts[0].kind.primitive == .exec and rawOuts[1].kind == .primitive and rawOuts[1].kind.primitive == .value;

                        //const valOuts = if (is_pure) rawOuts else rawOuts[1..];

                        slot.type =
                            if (is_pure) rawOuts[0].kind.primitive.value
                                //
                            else if (is_simple_0_out_impure)
                                primitive_types.void
                                    //
                            else if (is_simple_1_out_impure)
                                rawOuts[1].kind.primitive.value
                                    //
                            else _: {
                                // FIXME: the type should be stored on the NodeDesc, no?
                                // why make a temp?
                                const graphl_type_slot = try self.arena.allocator().create(TypeInfo);
                                graphl_type_slot.* = .{
                                    .name = pool.getSymbol("$TEMP_TYPE"),
                                    .subtype = .{ .func = func_node_desc },
                                    .size = 0,
                                };
                                break :_ graphl_type_slot;
                            };
                        try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);

                        const operands = try self.arena.allocator().alloc(byn.c.BinaryenExpressionRef, v.items.len - 1);
                        defer self.arena.allocator().free(operands);

                        for (v.items[1..], operands[0 .. v.items.len - 1]) |arg_idx, *operand| {
                            const arg_compiled = self._sexp_compiled[arg_idx];
                            operand.* = byn.c.BinaryenLocalGet(self.module.c(), arg_compiled.local_index, try self.getBynType(arg_compiled.type));
                        }

                        const call_expr = byn.c.BinaryenCall(
                            self.module.c(),
                            func.value.symbol,
                            operands.ptr,
                            @intCast(operands.len),
                            try self.getBynType(slot.type),
                        );

                        slot.expr = if (slot.type == primitive_types.void)
                            call_expr
                        else
                            byn.c.BinaryenLocalSet(self.module.c(), local_index, call_expr);

                        break :done;
                    }

                    // otherwise we have a non builtin
                    log.err("unhandled call: {}", .{code_sexp});
                    self.diag.err = .{ .UnhandledCall = code_sexp_idx };
                    return error.UnhandledCall;
                },

                .int => |v| {
                    slot.type = primitive_types.i32_;
                    try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                    slot.expr = byn.c.BinaryenLocalSet(self.module.c(), local_index, byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@intCast(v))));
                },

                .float => |v| {
                    slot.type = primitive_types.f64_;
                    try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                    slot.expr = byn.c.BinaryenLocalSet(self.module.c(), local_index, byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralFloat64(v)));
                },

                .symbol => |v| {
                    // FIXME: have a list of symbols in the scope (aka the env lol)
                    if (v.ptr == syms.true.value.symbol.ptr) {
                        slot.type = primitive_types.bool_;
                        try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                        slot.expr = byn.c.BinaryenLocalSet(self.module.c(), local_index, byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(1)));
                        break :done;
                    }

                    if (v.ptr == syms.false.value.symbol.ptr) {
                        slot.type = primitive_types.bool_;
                        try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
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
                    try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                    slot.expr = byn.c.BinaryenLocalSet(
                        self.module.c(),
                        local_index,
                        byn.c.BinaryenLocalGet(self.module.c(), info.ref, try self.getBynType(info.type)),
                    );
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
                        // FIXME: gross, use 0 terminated strings
                        v.ptr,
                        @intCast(v.len),
                    );

                    slot.type = primitive_types.string;
                    try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);

                    slot.expr = byn.c.BinaryenLocalSet(
                        self.module.c(),
                        local_index,
                        byn.c.BinaryenArrayNewData(
                            self.module.c(),
                            try self.getBynHeapType(primitive_types.string),
                            seg_name,
                            // TODO: consider using an offset?
                            byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(0)),
                            byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@intCast(v.len))),
                        ),
                    );

                    // TODO: handle overflow
                    self.ro_data_offset = std.math.add(u32, self.ro_data_offset, @intCast(v.len)) catch @panic("ro_data_offset overflow");
                },

                .bool => |v| {
                    slot.type = primitive_types.bool_;
                    try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                    slot.expr = byn.c.BinaryenLocalSet(
                        self.module.c(),
                        local_index,
                        byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(if (v) 1 else 0)),
                    );
                },

                .jump => {
                    slot.type = graphl_builtin.empty_type;
                    try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                    slot.expr = byn.c.BinaryenUnreachable(self.module.c());
                },

                .void => {
                    slot.type = graphl_builtin.empty_type;
                    try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                    slot.expr = byn.c.BinaryenNop(self.module.c());
                },

                // module is only the top level, and compilation is per-function
                .module => unreachable,

                .valref => |v| {
                    // FIXME: warn on forward value uses
                    const target_slot = &self._sexp_compiled[v.target];
                    slot.type = target_slot.type;
                    try fn_ctx.finalizeSlotTypeForSexp(self, code_sexp_idx);
                    slot.expr = byn.c.BinaryenLocalSet(
                        self.module.c(),
                        local_index,
                        byn.c.BinaryenLocalGet(
                            self.module.c(),
                            target_slot.local_index,
                            try self.getBynType(target_slot.type),
                        ),
                    );
                },
            }
        }

        // FIXME: fix sexp to contain a location
        // if (code_sexp.loc) |loc| {
        //     byn.c.BinaryenFunctionSetDebugLocation(
        //         fn_ctx.byn_func,
        //         slot.expr,
        //         self.file_byn_index,
        //         0,
        //         1, //code_sexp.loc,
        //     );
        // }
        slot.pre_block = byn.c.RelooperAddBlock(fn_ctx.relooper, byn.c.BinaryenNop(self.module.c()));
        slot.post_block = byn.c.RelooperAddBlock(fn_ctx.relooper, slot.expr);

        if (builtin.mode == .Debug) {
            // FIXME: use log.debug
            std.debug.print("compiled index {} type={s}, expr=\n{}\nto\n", .{ code_sexp_idx, slot.type.name, Sexp.printOneLine(self.graphlt_module, code_sexp_idx) });
            byn._BinaryenExpressionPrintStderr(slot.expr);
            std.debug.print("\n", .{});
        }
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
                // FIXME:
                // self.diag.err = .{ .InvalidTypeCoercion = .{
                //     .op = {},
                // } };
                // return error.InvalidTypeCoercion;
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
        func_type: *graphl_builtin.NodeDesc,

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
            // FIXME: is this still necessary now?
            // if (!BinaryenHelper.isValueType(slot.type.subtype)) {
            //     slot.frame_depth = self._frame_byte_size;
            //     self._frame_byte_size += slot.type.size;
            // } else {
            //     slot.frame_depth = 0xffff_ffff;
            // }

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
        const from_sexp = self.graphlt_module.get(from_idx);

        // HACK
        const is_return_expr = from_sexp.value == .list and from_sexp.value.list.items.len >= 1 and _: {
            const callee = self.graphlt_module.get(from_sexp.value.list.items[0]);
            break :_ callee.value == .symbol and callee.value.symbol.ptr == syms.@"return".value.symbol.ptr;
        };
        // if we're a return statement, don't allow non-epilogue connections to the post block
        if (is_return_expr and from_side == .post)
            return;

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

    fn RelooperAddBranchDirect(
        self: *const @This(),
        from_idx: u32,
        comptime from_side: enum { pre, post },
        to_block: byn.c.RelooperBlockRef,
        condition: byn.c.BinaryenExpressionRef,
        code: byn.c.BinaryenExpressionRef,
    ) void {
        const from_slot = &self._sexp_compiled[from_idx];
        const from_block = if (from_side == .pre) from_slot.pre_block else from_slot.post_block;
        if (builtin.mode == .Debug) {
            std.debug.print("from:0x{x}->to:0x{x}\n", .{ @intFromPtr(from_block), @intFromPtr(to_block) });
            std.debug.print("from:{s}:{}: {}\nto:{s}:{}: {s}\n", .{ @tagName(from_side), from_idx, Sexp.printOneLine(self.graphlt_module, from_idx), "post", 99999999, "EPILOGUE" });
        }
        byn.c.RelooperAddBranch(from_block, to_block, condition, code);
    }

    const LinkContext = struct {
        epilogue: byn.c.RelooperBlockRef,
    };

    // link (recursively) a sexp's control flow subgraph
    // - "if" will have conditional jumps and then both blocks jump to the post block
    // - jumps just jump
    // - all dependencies (typically arguments) are executed first in order
    fn linkExpr(
        self: *@This(),
        code_sexp_idx: u32,
        fn_ctx: *FnContext,
        link_ctx: *const LinkContext,
    ) CompileExprError!void {
        const code_sexp = self.graphlt_module.get(code_sexp_idx);
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
                    try self.linkExpr(list.items[2], fn_ctx, link_ctx);
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
                        byn.c.BinaryenLocalGet(self.module.c(), condition_slot.local_index, try self.getBynType(condition_slot.type)),
                        null,
                    );
                    self.RelooperAddBranch(consequence_idx, .post, code_sexp_idx, .post, null, null);
                    try self.linkExpr(consequence_idx, fn_ctx, link_ctx);
                    if (list.items.len > 3) {
                        const alternative_idx = code_sexp.value.list.items[3];
                        try self.linkExpr(condition_idx, fn_ctx, link_ctx);
                        try self.linkExpr(alternative_idx, fn_ctx, link_ctx);
                        self.RelooperAddBranch(condition_idx, .post, alternative_idx, .pre, null, null);
                        self.RelooperAddBranch(alternative_idx, .post, code_sexp_idx, .post, null, null);
                    } else {
                        try self.linkExpr(condition_idx, fn_ctx, link_ctx);
                        self.RelooperAddBranch(condition_idx, .post, code_sexp_idx, .pre, null, null);
                    }
                } else { // otherwise begin, return, define, or function call // TODO: macros
                    const items = if (callee.value.symbol.ptr == syms.define.value.symbol.ptr) list.items[2..] else list.items[1..];

                    for (items) |item| {
                        try self.linkExpr(item, fn_ctx, link_ctx);
                    }

                    if (items.len > 0) {
                        const first_item = items[0];
                        const last_item = items[items.len - 1];

                        self.RelooperAddBranch(code_sexp_idx, .pre, first_item, .pre, null, null);

                        for (items[0 .. items.len - 1], items[1..]) |prev, next| {
                            self.RelooperAddBranch(prev, .post, next, .pre, null, null);
                        }

                        self.RelooperAddBranch(last_item, .post, code_sexp_idx, .post, null, null);
                    } else {
                        self.RelooperAddBranch(code_sexp_idx, .pre, code_sexp_idx, .post, null, null);
                    }

                    if (callee.value.symbol.ptr == syms.@"return".value.symbol.ptr) {
                        self.RelooperAddBranchDirect(code_sexp_idx, .post, link_ctx.epilogue, null, null);
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

            /// a user func thunk will copy its argument fields into transfer memory, with the host
            /// requesting any arrays. Then the user function will write any arrays and transfer the
            /// result fields.
            pub fn addImport(_self: @This(), ctx: *Compilation, in_name: [:0]const u8) !void {
                const param_types = try ctx.arena.allocator().alloc(byn.c.BinaryenType, 1 + _self.params.len);
                //defer ctx.arena.allocator().free(param_types); // consider using diff allocator
                param_types[0] = byn.c.BinaryenTypeInt32();
                for (_self.params, param_types[1..]) |graphl_t, *wasm_t| {
                    wasm_t.* = try ctx.getBynType(graphl_t);
                }
                const byn_params = byn.c.BinaryenTypeCreate(param_types.ptr, @intCast(param_types.len));

                const byn_result = if (_self.results.len == 0) byn.c.BinaryenTypeNone()
                    //
                    else if (_self.results.len == 1) try ctx.getBynType(_self.results[0])
                    //
                    else _: {
                        const graphl_type_slot = try ctx.arena.allocator().create(TypeInfo);
                        graphl_type_slot.* = .{
                            .name = in_name,
                            .size = 0,
                            .subtype = .{ .@"struct" = try .initFromTypeList(ctx.arena.allocator(), .{
                                .field_types = _self.results,
                                .field_names = result_names_cached[0.._self.results.len],
                            }) },
                        };
                        break :_ try ctx.getBynType(graphl_type_slot);
                    };

                byn.c.BinaryenAddFunctionImport(ctx.module.c(), in_name, "env", in_name, byn_params, byn_result);
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

                for (params, def.params, byn_params) |param, *param_type, *byn_param| {
                    param_type.* = param.kind.primitive.value;
                    byn_param.* = try self.getBynType(param.kind.primitive.value);
                }
                for (results, def.results) |result, *result_type| {
                    result_type.* = result.kind.primitive.value;
                }

                var byn_args = try std.ArrayListUnmanaged(*byn.Expression).initCapacity(self.arena.allocator(), 1 + byn_params.len);
                defer byn_args.deinit(self.arena.allocator());
                byn_args.appendAssumeCapacity(@ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(@intCast(user_func.data.id)))));
                byn_args.expandToCapacity();

                for (params, 0.., byn_args.items[1..]) |p, i, *byn_arg| {
                    byn_arg.* = byn.Expression.localGet(self.module, @intCast(i), @enumFromInt(try self.getBynType(p.kind.primitive.value)));
                }

                const import_entry = try userfunc_imports.getOrPut(self.arena.allocator(), def);

                const thunk_name = _: {
                    if (!import_entry.found_existing) {
                        import_entry.value_ptr.* = try def.name(self.arena.allocator());
                    }
                    break :_ import_entry.value_ptr.*;
                };

                const byn_param = byn.c.BinaryenTypeCreate(byn_params.ptr, @intCast(byn_params.len));
                const byn_result = if (results.len > 1) byn.c.BinaryenTypeInt32()
                    //
                    else if (results.len == 0) byn.c.BinaryenTypeNone()
                    //
                    else try self.getBynType(results[0].kind.primitive.value);

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
            _ = vec3_module;

            // TODO: add vec3-length function
            //std.debug.assert(byn._binaryenCloneFunction(vec3_module, self.module.c(), "__graphl_vec3_x".ptr, "Vec3->X".ptr));
        }

        if (self.used_features.string) {
            const str_byn_type = try self.getBynType(primitive_types.string);

            // FIXME: gross, maybe go back to reading/linking my own compiled wat? I don't think
            // the types would line up though...
            std.debug.assert(self.module.addFunction(
                "__graphl_host_copy",
                @enumFromInt(byn.c.BinaryenTypeCreate(@constCast(&[_]byn.c.BinaryenType{
                    str_byn_type, // array/string ref (;0;)
                    @intFromEnum(byn.Type.i32), // starting offset (;1;)
                }), 2)),
                byn.Type.i32, // returns bytes written, not done until 0 are written
                &.{
                    .i32, // $arr_len (;2;)
                    .i32, // $index (;3;)
                },
                try byn.Expression.block(
                    self.module,
                    null,
                    @constCast(&[_]*byn.Expression{
                        // (local.set $index $second_param)
                        @as(*byn.Expression, @ptrCast(byn.c.BinaryenLocalSet(
                            self.module.c(),
                            3,
                            byn.c.BinaryenLocalGet(self.module.c(), 1, @intFromEnum(byn.Type.i32)),
                        ))),
                        // (local.set $arr_len (array.len (local.get $arr)))
                        @as(*byn.Expression, @ptrCast(byn.c.BinaryenLocalSet(
                            self.module.c(),
                            2,
                            byn.c.BinaryenArrayLen(
                                self.module.c(),
                                byn.c.BinaryenLocalGet(self.module.c(), 0, str_byn_type),
                            ),
                        ))),
                        // (if
                        //   (i32.ge_u
                        //     (local.get $index)
                        //     (local.get $arr_len)))
                        //   (return (i32.const 0))))
                        @as(*byn.Expression, @ptrCast(byn.c.BinaryenIf(
                            self.module.c(),
                            @ptrCast(byn.Expression.binaryOp(
                                self.module,
                                byn.Expression.Op.geUInt32(),
                                @ptrCast(byn.c.BinaryenLocalGet(self.module.c(), 3, @intFromEnum(byn.Type.i32))),
                                @ptrCast(byn.c.BinaryenLocalGet(self.module.c(), 2, @intFromEnum(byn.Type.i32))),
                            )),
                            @ptrCast(byn.c.BinaryenReturn(
                                self.module.c(),
                                @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(0))),
                            )),
                            null,
                        ))),
                        // (loop $loop ...
                        @as(*byn.Expression, @ptrCast(byn.c.BinaryenLoop(
                            self.module.c(),
                            "loop",
                            @ptrCast(try byn.Expression.block(
                                self.module,
                                null,
                                @constCast(&[_]*byn.Expression{
                                    // (i32.store
                                    //     (array.get_u 0
                                    //         (local.get $arr)
                                    //         (local.get $index)))
                                    @as(*byn.Expression, @ptrCast(byn.c.BinaryenStore(
                                        self.module.c(),
                                        4,
                                        0,
                                        1, // TODO: alignment
                                        @ptrCast(byn.Expression.binaryOp(
                                            self.module,
                                            byn.Expression.Op.addInt32(),
                                            @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(mem_start))),
                                            @ptrCast(byn.Expression.binaryOp(
                                                self.module,
                                                byn.Expression.Op.subInt32(),
                                                @ptrCast(byn.c.BinaryenLocalGet(self.module.c(), 3, @intFromEnum(byn.Type.i32))),
                                                @ptrCast(byn.c.BinaryenLocalGet(self.module.c(), 1, @intFromEnum(byn.Type.i32))),
                                            )),
                                        )),
                                        byn.c.BinaryenArrayGet(
                                            self.module.c(),
                                            byn.c.BinaryenLocalGet(self.module.c(), 0, str_byn_type),
                                            byn.c.BinaryenLocalGet(self.module.c(), 3, @intFromEnum(byn.Type.i32)),
                                            @intFromEnum(byn.Type.i32),
                                            false,
                                        ),
                                        @intFromEnum(byn.Type.i32),
                                        main_mem_name,
                                    ))),
                                    // (local.set $index
                                    //   (i32.add
                                    //     (local.get $index)
                                    //     (i32.const 1)))
                                    @as(*byn.Expression, @ptrCast(byn.c.BinaryenLocalSet(
                                        self.module.c(),
                                        3,
                                        @ptrCast(byn.Expression.binaryOp(
                                            self.module,
                                            byn.Expression.Op.addInt32(),
                                            @ptrCast(byn.c.BinaryenLocalGet(self.module.c(), 3, @intFromEnum(byn.Type.i32))),
                                            @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(1))),
                                        )),
                                    ))),
                                    // (br_if $loop
                                    //   (i32.lt_u
                                    //     (local.get $index)
                                    //     (local.get $arr_len)))
                                    @as(*byn.Expression, @ptrCast(byn.c.BinaryenBreak(
                                        self.module.c(),
                                        "loop",
                                        @ptrCast(byn.Expression.binaryOp(
                                            self.module,
                                            byn.Expression.Op.ltUInt32(),
                                            @ptrCast(byn.c.BinaryenLocalGet(self.module.c(), 3, @intFromEnum(byn.Type.i32))),
                                            @ptrCast(byn.c.BinaryenLocalGet(self.module.c(), 2, @intFromEnum(byn.Type.i32))),
                                        )),
                                        null,
                                    ))),
                                    // (if
                                    //   (i32.ge_u
                                    //     (local.get $index)
                                    //     (i32.const 4096))
                                    //   (then (return 4096)))
                                    @as(*byn.Expression, @ptrCast(byn.c.BinaryenIf(
                                        self.module.c(),
                                        @ptrCast(byn.Expression.binaryOp(
                                            self.module,
                                            byn.Expression.Op.geUInt32(),
                                            @ptrCast(byn.c.BinaryenLocalGet(self.module.c(), 3, @intFromEnum(byn.Type.i32))),
                                            @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(str_transfer_seg_size))),
                                        )),
                                        @ptrCast(byn.c.BinaryenReturn(
                                            self.module.c(),
                                            @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(str_transfer_seg_size))),
                                        )),
                                        null,
                                    ))),
                                }),
                                @enumFromInt(byn.c.BinaryenTypeAuto()),
                            )),
                        ))),
                        @as(*byn.Expression, @ptrCast(byn.c.BinaryenStore(
                            self.module.c(),
                            4,
                            0,
                            0,
                            @ptrCast(byn.Expression.binaryOp(
                                self.module,
                                byn.Expression.Op.addInt32(),
                                @ptrCast(byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(mem_start))),
                                @ptrCast(byn.c.BinaryenLocalGet(self.module.c(), 3, @intFromEnum(byn.Type.i32))),
                            )),
                            byn.c.BinaryenConst(self.module.c(), byn.c.BinaryenLiteralInt32(0)),
                            @intFromEnum(byn.Type.i32),
                            main_mem_name,
                        ))),
                        // FIXME: can't break to this without a named block break!
                        @as(*byn.Expression, @ptrCast(byn.c.BinaryenReturn(
                            self.module.c(),
                            @ptrCast(byn.Expression.binaryOp(
                                self.module,
                                byn.Expression.Op.subInt32(),
                                @ptrCast(byn.c.BinaryenLocalGet(self.module.c(), 3, @intFromEnum(byn.Type.i32))),
                                @ptrCast(byn.c.BinaryenLocalGet(self.module.c(), 1, @intFromEnum(byn.Type.i32))),
                            )),
                        ))),
                    }),
                    .none,
                ),
            ) != null);

            std.debug.assert(byn.c.BinaryenAddFunctionExport(self.module.c(), "__graphl_host_copy", "__graphl_host_copy") != null);
        }

        //FIXME: remove this
        //if (std.log.logEnabled(.debug, .graphlt_compiler)) {
        byn._BinaryenModulePrintStderr(self.module.c());
        //}

        // FIXME: define a compiler-version independent spec for this data
        var function_data = try std.ArrayListUnmanaged(struct {
            name: []const u8,
            inputs: []const []const u8,
            outputs: []const []const u8,
        }).initCapacity(self.arena.allocator(), self.deferred.func_decls.count());
        defer function_data.deinit(self.arena.allocator());

        {
            std.debug.assert(self.deferred.func_decls.count() == self.deferred.func_types.count());
            var func_decl_iter = self.deferred.func_decls.iterator();

            while (func_decl_iter.next()) |func_decl_entry| {
                //const func_decl = func_decl_entry.value_ptr;
                const func_type = self.deferred.func_types.getPtr(func_decl_entry.key_ptr.*) orelse unreachable;
                const inputs = try self.arena.allocator().alloc([]const u8, func_type.param_types.len);
                for (inputs, func_type.param_types) |*i, param| {
                    i.* = param.name;
                }
                const outputs = try self.arena.allocator().alloc([]const u8, func_type.result_types.len);
                for (outputs, func_type.result_types) |*i, result| {
                    i.* = result.name;
                }

                function_data.appendAssumeCapacity(.{
                    .name = func_decl_entry.key_ptr.*,
                    .inputs = inputs,
                    .outputs = outputs,
                });
            }
        }

        // TODO: dealloc after adding
        const graphl_meta_custom_data_json = try std.json.stringifyAlloc(self.arena.allocator(), .{
            // FIXME: this is an expediant hack, define a JSON schema that will remain
            .token = "63a7f259-5c6b-4206-8927-8102dc9ad34d",
            .functions = function_data.items,
            // FIXME: also define types
            .types = &[_](struct { name: []const u8 }){},
        }, .{});

        byn.c.BinaryenAddCustomSection(
            self.module.c(),
            "graphl_meta",
            graphl_meta_custom_data_json.ptr,
            @intCast(graphl_meta_custom_data_json.len),
        );

        if (opts.optimize != .none) {
            byn.c.BinaryenModuleOptimize(self.module.c());
        }

        if (!byn._BinaryenModuleValidateWithOpts(
            self.module.c(),
            @enumFromInt( //@intFromEnum(byn.Flags.quiet) |
            @intFromEnum(byn.Flags.globally)),
        )) {
            // TODO: get validation result from Binaryen and store in the error
            // FIXME/TEMP: for some reason this is causing an issue valiating in binaryen,
            // but the generated output is fine... try the "vec3 ref" test
            //self.diag.err = .InvalidIR;
            //return error.InvalidIR;
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
        \\  (type (;5;) (func (param i32 i32)))
        \\  (type (;6;) (func (param i32 (ref null 0))))
        \\  (import "env" "callUserFunc_i32_R" (func (;0;) (type 5)))
        \\  (import "env" "callUserFunc_code_R" (func (;1;) (type 6)))
        \\  (memory (;0;) 1 256)
        \\  (export "memory" (memory 0))
        \\  (export "++" (func $++))
        \\  (export "deep" (func $deep))
        \\  (export "ifs" (func $ifs))
        \\  (func $sql (;2;) (type 2) (param (ref null 0))
        \\    i32.const 1
        \\    local.get 0
        \\    call 1
        \\  )
        \\  (func $Confetti (;3;) (type 3) (param i32)
        \\    i32.const 0
        \\    local.get 0
        \\    call 0
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
        \\  (memory (;0;) 1 256)
        \\  (export "memory" (memory 0))
        \\  (export "factorial" (func $factorial))
        \\  (func $factorial (;0;) (type 0) (param i32) (result i32)
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
        \\        unreachable
        \\      else
        \\        br 1 (;@1;)
        \\      end
        \\      unreachable
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
        \\    call $factorial
        \\    local.set 14
        \\    local.get 13
        \\    local.get 14
        \\    i32.mul
        \\    local.set 12
        \\    local.get 12
        \\    return
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
        \\        (begin (ModelCenter) <!__label1 ;; FIXME: this is unintuitive...
        \\               (if (> (.y #!__label1)
        \\                      2)
        \\                   (return "my_export")
        \\                   (return "EXPORT2"))))
    , null);
    //std.debug.print("{any}\n", .{parsed});
    // FIXME: there is some double-free happening here?
    defer parsed.deinit();

    const expected =
        \\(module
        \\  (type (;0;) (array (mut i8)))
        \\  (type (;1;) (func (param i32)))
        \\  (type (;2;) (func (param i64 i32 i32) (result (ref null 0))))
        \\  (type (;3;) (func (param i32 i32)))
        \\  (type (;4;) (func (param (ref null 0) i32) (result i32)))
        \\  (import "env" "callUserFunc_R_vec3" (func (;0;) (type 3)))
        \\  (memory (;0;) 1 256)
        \\  (global $__gstkp (;0;) (mut i32) i32.const 5120)
        \\  (export "memory" (memory 0))
        \\  (export "processInstance" (func $processInstance))
        \\  (export "__graphl_host_copy" (func $__graphl_host_copy))
        \\  (func $ModelCenter (;1;) (type 1) (param i32)
        \\    i32.const 0
        \\    local.get 0
        \\    call 0
        \\  )
        \\  (func $processInstance (;2;) (type 2) (param i64 i32 i32) (result (ref null 0))
        \\    (local (ref null 0) (ref null 0) (ref null 0) (ref null 0) (ref null 0) (ref null 0) (ref null 0) i32 i32 i32 i32 f64)
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        global.get $__gstkp
        \\        i32.const 0
        \\        i32.add
        \\        local.set 10
        \\        global.get $__gstkp
        \\        i32.const 0
        \\        i32.add
        \\        call $ModelCenter
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        local.get 10
        \\        local.set 12
        \\        local.get 12
        \\        i32.const 8
        \\        i32.add
        \\        f64.load align=4
        \\        local.set 14
        \\      end
        \\      br 0 (;@1;)
        \\    end
        \\    block ;; label = @1
        \\      block ;; label = @2
        \\        i32.const 2
        \\        local.set 13
        \\        local.get 14
        \\        local.get 13
        \\        i64.extend_i32_s
        \\        f32.convert_i64_s
        \\        f64.promote_f32
        \\        f64.gt
        \\        local.set 11
        \\      end
        \\      local.get 11
        \\      if ;; label = @2
        \\        i32.const 0
        \\        i32.const 9
        \\        array.new_data 0 $s_5120
        \\        local.set 7
        \\        local.get 7
        \\        return
        \\      else
        \\        i32.const 0
        \\        i32.const 7
        \\        array.new_data 0 $s_5129
        \\        local.set 9
        \\        local.get 9
        \\        return
        \\      end
        \\      unreachable
        \\    end
        \\    unreachable
        \\  )
        \\  (func $__graphl_host_copy (;3;) (type 4) (param (ref null 0) i32) (result i32)
        \\    (local i32 i32)
        \\    local.get 1
        \\    local.set 3
        \\    local.get 0
        \\    array.len
        \\    local.set 2
        \\    local.get 3
        \\    local.get 2
        \\    i32.ge_u
        \\    if ;; label = @1
        \\      i32.const 0
        \\      return
        \\    end
        \\    loop ;; label = @1
        \\      i32.const 1024
        \\      local.get 3
        \\      local.get 1
        \\      i32.sub
        \\      i32.add
        \\      local.get 0
        \\      local.get 3
        \\      array.get_u 0
        \\      i32.store align=1
        \\      local.get 3
        \\      i32.const 1
        \\      i32.add
        \\      local.set 3
        \\      local.get 3
        \\      local.get 2
        \\      i32.lt_u
        \\      br_if 0 (;@1;)
        \\      local.get 3
        \\      i32.const 4096
        \\      i32.ge_u
        \\      if ;; label = @2
        \\        i32.const 4096
        \\        return
        \\      end
        \\    end
        \\    i32.const 1024
        \\    local.get 3
        \\    i32.add
        \\    i32.const 0
        \\    i32.store
        \\    local.get 3
        \\    local.get 1
        \\    i32.sub
        \\    return
        \\  )
        \\  (data $s_5120 (;0;) "my_export")
        \\  (data $s_5129 (;1;) "EXPORT2")
        \\  (@custom "sourceMappingURL" (after data) "\07/script")
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
