const std = @import("std");
const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;
const builtin = @import("./nodes/builtin.zig");
const binaryen = @import("binaryen");

pub const Diagnostic = struct {
    err: Error = .None,

    // context
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
    // TODO: use interning and env!
    typeof_map: std.StringHashMapUnmanaged(builtin.Type),
    wasm_module: *binaryen.Module,
    is_wasm_module_moved: bool = false,
    arena: std.heap.ArenaAllocator,
    diag: *Diagnostic,

    pub fn init(alloc: std.mem.Allocator, in_diag: *Diagnostic) !@This() {
        return .{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .typeof_map = .{},
            .diag = in_diag,
            .wasm_module = binaryen.Module.init(),
        };
    }

    pub fn deinit(self: *@This()) void {
        const alloc = self.arena.allocator();
        // NOTE: this is a no-op because of the arena
        self.typeof_map.deinit(alloc);
        self.arena.deinit();
        if (!self.is_wasm_module_moved)
            self.wasm_module.deinit();
    }

    /// must be passed a list
    fn compileFunc(self: *@This(), sexp: *const Sexp) !void {
        _ = self;

        if (sexp.value != .list) return error.NotAFuncDecl;
        if (sexp.value.list.items.len == 0) return error.NotAFuncDecl;
        if (sexp.value.list.items[0].value != .symbol) return error.NonSymbolHead;

        // FIXME: parser should be aware of the define form!
        //if (sexp.value.list.items[0].value.symbol.ptr != syms.define.value.symbol.ptr) return error.NotAFuncDecl;
        if (!std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.define.value.symbol)) return error.NotAFuncDecl;

        if (sexp.value.list.items[1].value != .list) return error.NotAFuncDecl;
        if (sexp.value.list.items[1].value.list.items.len < 1) return error.FuncBindingsListEmpty;
        for (sexp.value.list.items[1].value.list.items) |*def_item| {
            if (def_item.value != .symbol) return error.FuncParamBindingNotSymbol;
        }

        const func_name = sexp.value.list.items[1].value.list.items[0].value.symbol;
        //const params = sexp.value.list.items[1].value.list.items[1..];
        const func_name_mangled = func_name;
        _ = func_name_mangled;

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
    }

    fn compileTypeOf(self: *@This(), sexp: *const Sexp) !void {
        if (sexp.value != .list) return error.TypeDeclNotList;
        if (sexp.value.list.items.len == 0) return error.TypeDeclListEmpty;
        if (sexp.value.list.items[0].value != .symbol) return error.NonSymbolHead;
        // FIXME: parser should be aware of the define form!
        //std.debug.assert(sexp.value.list.items[0].value.symbol.ptr == syms.typeof.value.symbol.ptr);
        if (!std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.typeof.value.symbol)) return error.NotATypeDecl;

        // TODO: support non function types
        self.compileTypeOfFunc(sexp) catch |e| switch (e) {
            error.NotAFuncTypeDecl => {},
            else => return e,
        };
        self.compileTypeOfVar(sexp) catch |e| switch (e) {
            error.NotAVarTypeDecl => {},
            else => return e,
        };

        //const func_name = sexp.value.list.items[1].value.list.items[0].value.symbol;
        //const args = sexp.value.list.items[1].value.list.items[1..];

        // FIXME: wrong
        // _ = try writer.write(
        //     \\(type (;0;) (func (param i32 i32)))
        // );
    }

    /// receives (typeof (f i32) i32)
    fn compileTypeOfFunc(self: *@This(), sexp: *const Sexp) !void {
        _ = self;
        std.debug.assert(sexp.value == .list);
        std.debug.assert(sexp.value.list.items[0].value == .symbol);
        // FIXME: parser should be aware of the define form!
        //std.debug.assert(sexp.value.list.items[0].value.symbol.ptr == syms.typeof.value.symbol.ptr);
        std.debug.assert(std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.typeof.value.symbol));

        if (sexp.value.list.items[1].value != .list) return error.NotAFuncTypeDecl;
        if (sexp.value.list.items[1].value.list.items.len == 0) return error.FuncTypeDeclListEmpty;
        for (sexp.value.list.items[1].value.list.items) |*def_item| {
            // function argument names must be symbols
            if (def_item.value != .symbol) return error.FuncBindingsListEmpty;
        }

        const func_name = sexp.value.list.items[1].value.list.items[0].value.symbol;
        _ = func_name;
        //const result_type_name = sexp.value.list.items[2].value.list.items[0];
        //_ = result_type_name;

        // TODO: use env
        //self.typeof_map.put(self.alloc, type_name, type_);
    }

    fn compileTypeOfVar(self: *@This(), sexp: *const Sexp) !void {
        _ = self;
        std.debug.assert(sexp.value == .list);
        std.debug.assert(sexp.value.list.items[0].value == .symbol);
        // FIXME: parser should be aware of the define form!
        //std.debug.assert(sexp.value.list.items[0].value.symbol.ptr == syms.typeof.value.symbol.ptr);
        std.debug.assert(std.mem.eql(u8, sexp.value.list.items[0].value.symbol, syms.typeof.value.symbol));

        if (sexp.value.list.items[1].value != .symbol) return error.NotAVarTypeDecl;
        // shit, I need to evaluate macros in the compiler, don't I
        if (sexp.value.list.items[2].value != .symbol) return error.VarTypeNotSymbol;

        const var_name = sexp.value.list.items[1].value.symbol;
        _ = var_name;
        const type_name = sexp.value.list.items[2].value.symbol;
        _ = type_name;

        // TODO: use env
        //self.typeof_map.put(self.alloc, type_name, type_);
    }

    pub fn compileModule(self: *@This(), sexp: *const Sexp) !*binaryen.Module {
        std.debug.assert(sexp.value == .module);

        for (sexp.value.module.items) |decl| {
            switch (decl.value) {
                .list => {
                    self.compileFunc(&decl) catch |e| switch (e) {
                        error.NotAFuncDecl => {},
                        // TODO: aggregate errors
                        else => {
                            std.debug.print("failed: {}\n", .{decl});
                            return e;
                        },
                    };
                    self.compileTypeOf(&decl) catch |e| switch (e) {
                        error.NotATypeDecl => {},
                        else => {
                            std.debug.print("failed: {}\n", .{decl});
                            return e;
                        },
                    };
                    // self.compileVar(form, writer) catch |e| switch (e) {
                    //     error.NotAVarDecl => {},
                    //     else => return e,
                    // };
                },
                else => {
                    self.diag.err = Diagnostic.Error{ .BadTopLevelForm = &decl };
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
        std.debug.print("wat:\n{s}\n", .{result.emitText()});
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
    }
}
