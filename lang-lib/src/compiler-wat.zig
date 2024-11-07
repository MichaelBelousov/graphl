const std = @import("std");
const Sexp = @import("./sexp.zig").Sexp;
const Env = @import("./nodes//builtin.zig").Env;
const TypeInfo = @import("./nodes//builtin.zig").TypeInfo;
const Type = @import("./nodes//builtin.zig").Type;
const syms = @import("./sexp.zig").syms;
const primitive_type_syms = @import("./sexp.zig").primitive_type_syms;
const builtin = @import("./nodes/builtin.zig");
const PageWriter = @import(".//PageWriter.zig").PageWriter;

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
    result_names: []const []const u8,
};

const DeferredFuncTypeInfo = struct {
    param_types: []const Type,
    result_types: []const Type,
};

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
    diag: *Diagnostic,

    pub fn init(alloc: std.mem.Allocator, in_diag: *Diagnostic) !@This() {
        const result = @This(){
            .arena = std.heap.ArenaAllocator.init(alloc),
            .diag = in_diag,
            // FIXME: these are set in the main public entry, once we know
            // the caller has settled on where they are putting this object
            .env = undefined,
            .wat = undefined,
            .module_body = undefined,
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

        const param_names = try alloc.alloc([]const u8, func_bindings.len);

        const func_desc = DeferredFuncDeclInfo{
            .param_names = param_names,
            // TODO: read all defines at beginning of sexp or something
            .local_names = &.{},
            .local_types = &.{},
            .result_names = &.{},
        };

        for (func_bindings, param_names) |func_binding, *param_name| {
            param_name.* = func_binding.value.symbol;
        }

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
        for (param_type_exprs, param_types) |type_expr, *type_| {
            const param_type = type_expr.value.symbol;
            type_.* = self.env.types.get(param_type) orelse return error.UnknownType;
        }

        const result_types = try alloc.alloc(Type, 1);
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
        pub const module = Sexp{ .value = .{ .symbol = "module" } };
        pub const @"type" = Sexp{ .value = .{ .symbol = "type" } };
        pub const @"export" = Sexp{ .value = .{ .symbol = "export" } };
        pub const func = Sexp{ .value = .{ .symbol = "func" } };
        pub const param = Sexp{ .value = .{ .symbol = "param" } };
        pub const result = Sexp{ .value = .{ .symbol = "result" } };
        pub const local = Sexp{ .value = .{ .symbol = "local" } };
        pub const ops = struct {
            pub const @"local.get" = Sexp{ .value = .{ .symbol = "local.get" } };
            pub const @"i32.add" = Sexp{ .value = .{ .symbol = "i32.add" } };
            pub const @"i32.const" = Sexp{ .value = .{ .symbol = "i32.add" } };
        };
        pub const memory = Sexp{ .value = .{ .symbol = "memory" } };
        pub const @"$0" = Sexp{ .value = .{ .symbol = "$0" } };
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

        {
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
            result_sexp.value.list.addOneAssumeCapacity().* = primitive_type_syms.i32;
        }

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
            // FIXME: compile return type
            result_sexp.value.list.addOneAssumeCapacity().* = primitive_type_syms.i32;

            for (func_decl.local_names, complete_func_type_desc.func_type.?.local_types) |local_name, local_type| {
                const local_sexp = try impl_sexp.value.list.addOne();
                local_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                try local_sexp.value.list.ensureTotalCapacityPrecise(3);
                (try local_sexp.value.list.addOne()).* = wat_syms.local;
                (try local_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = try std.fmt.allocPrint(alloc, "$local_{s}", .{local_name}) } };
                (try local_sexp.value.list.addOne()).* = Sexp{ .value = .{ .symbol = local_type.name } };
            }

            // FIXME: test generated stub
            const add_sexp = try impl_sexp.value.list.addOne();
            add_sexp.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try add_sexp.value.list.ensureTotalCapacityPrecise(3);
            (try add_sexp.value.list.addOne()).* = wat_syms.ops.@"i32.add";

            const lhs = try add_sexp.value.list.addOne();
            lhs.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try lhs.value.list.ensureTotalCapacityPrecise(2);
            (try lhs.value.list.addOne()).* = wat_syms.ops.@"local.get";
            (try lhs.value.list.addOne()).* = Sexp{ .value = .{ .symbol = "$local_x" } };

            const rhs = try add_sexp.value.list.addOne();
            rhs.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
            try rhs.value.list.ensureTotalCapacityPrecise(2);
            (try rhs.value.list.addOne()).* = wat_syms.ops.@"local.get";
            (try rhs.value.list.addOne()).* = Sexp{ .value = .{ .symbol = "$local_x" } };
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

        // set these since they are inited to undefined
        self.env = try Env.initDefault(self.arena.allocator());
        self.wat = Sexp{ .value = .{ .module = std.ArrayList(Sexp).init(self.arena.allocator()) } };
        try self.wat.value.module.ensureTotalCapacityPrecise(1);
        const module_body = self.wat.value.module.addOneAssumeCapacity();
        module_body.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.arena.allocator()) } };
        self.module_body = &module_body.value.list;
        try self.module_body.ensureTotalCapacity(5);
        self.module_body.addOneAssumeCapacity().* = wat_syms.module;

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

        var page_writer = try PageWriter.init(self.arena.allocator());
        _ = try self.wat.write(page_writer.writer());
        // use arena parent so that when the arena deinit's, this remains,
        // and the caller can own the memory
        return page_writer.concat(self.arena.child_allocator);
    }
};

pub fn compile(a: std.mem.Allocator, sexp: *const Sexp, _in_diagnostic: ?*Diagnostic) ![]const u8 {
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
    var parsed = try SexpParser.parse(t.allocator,
        \\;;; comment
        \\(typeof x i32)
        \\(define x 10)
        \\;;; comment
        \\(typeof (++ i32) i32)
        \\(define (++ x) (+ x 1))
    , null);
    //std.debug.print("{any}\n", .{parsed});
    defer parsed.deinit(t.allocator);

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, &parsed, &diagnostic)) |wat| {
        defer t.allocator.free(wat);
        try t.expectEqualStrings(
            \\(module (memory $0
            \\                0)
            \\        (export "memory"
            \\                (memory $0))
            \\        (export "++"
            \\                (func $++))
            \\        (type $typeof_++
            \\              (func (param i32)
            \\                    (result i32)))
            \\        (func $++
            \\              (param $param_x
            \\                     i32)
            \\              (result i32)
            \\              (local $local_x
            \\                     i32)
            \\              (i32.add (local.get $local_x)
            \\                       (local.get $local_x))))
        , wat);
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
    }
}
