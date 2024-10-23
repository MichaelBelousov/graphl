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
    wasm_module: binaryen.Module,
    diag: *Diagnostic,

    pub fn init(in_diag: *Diagnostic) !@This() {
        return .{
            .typeof_map = .{},
            .diag = in_diag,
            .wasm_module = binaryen.Module.create(),
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.typeof_map.deinit(alloc);
        self.wasm_module.destroy();
    }

    pub fn compileFunc(self: *@This(), sexp: *const Sexp) !void {
        _ = self;

        if (sexp.value != .list) return error.FuncDeclNotList;
        if (sexp.value.list.items.len < 1) return error.FuncDeclListEmpty;
        if (sexp.value.list.items[0].value != .symbol) return error.FuncDeclInvalidDefine;
        if (sexp.value.list.items[0].value.symbol.ptr != syms.define.value.symbol.ptr) return error.FuncDeclInvalidDefine;
        if (sexp.value.list.items[1].value != .list) return error.FuncBindingsNotList;
        if (sexp.value.list.items[1].value.list.items.len < 1) return error.FuncBindingsListEmpty;
        for (sexp.value.list.items[1].value.list.items) |*def_item| {
            if (def_item.value != .symbol) return error.FuncParamBindingNotSymbol;
        }

        const func_name = sexp.value.list.items[1].value.list.items[0].value.symbol;
        //const params = sexp.value.list.items[1].value.list.items[1..];
        const func_name_mangled = func_name; // FIXME: mangle
        _ = func_name_mangled;

        // TODO: search for types first
        // const type_info = self.typeof_map.getPtr(func_name) orelse error.NoSuchType;
        // if (type_info != .@"fn") {
        //     // TODO: fill diagnostic here
        //     return error.FuncBadType;
        // }
    }

    pub fn compileTypeOf(self: *@This(), sexp: *const Sexp) void {
        _ = self;
        std.debug.assert(sexp.value == .list);
        std.debug.assert(sexp.value.list.items.len >= 1);
        std.debug.assert(sexp.value.list.items[0].value == .symbol);
        std.debug.assert(sexp.value.list.items[0].value.symbol.ptr == syms.typeof.value.symbol.ptr);
        std.debug.assert(sexp.value.list.items[1].value == .list);
        std.debug.assert(sexp.value.list.items[1].value.list.items.len >= 1);
        for (sexp.value.list.items[1].value.list.items) |*def_item| {
            // function argument names must be symbols
            std.debug.assert(def_item.value == .symbol);
        }

        //const func_name = sexp.value.list.items[1].value.list.items[0].value.symbol;
        //const args = sexp.value.list.items[1].value.list.items[1..];
    }

    /// returns the wasm binary blob result
    pub fn compileModule(self: *@This(), sexp: *const Sexp) !binaryen.Module {
        std.debug.assert(sexp.value == .module);

        for (sexp.value.module.items) |decl| {
            switch (decl.value) {
                .list => |forms| {
                    for (forms.items) |*form| {
                        // TODO: aggregate errors
                        self.compileFunc(form) catch continue;
                    }
                },
                else => {
                    self.diag.err = Diagnostic.Error{ .BadTopLevelForm = &decl };
                },
            }
        }

        // FIXME: need to free this!
        const wasm_module = self.wasm_module;
        self.wasm_module = undefined; // FIXME: need to remove deinit's pointer to this
        return wasm_module;
    }
};

pub fn compile(a: std.mem.Allocator, sexp: *const Sexp, _in_diagnostic: ?*Diagnostic) !binaryen.Module {
    var ignored_diagnostic: Diagnostic = undefined; // FIXME: why don't we init?
    const diag = if (_in_diagnostic) |d| d else &ignored_diagnostic;
    diag.module = sexp;

    var unit = try Compilation.init(diag);
    defer unit.deinit(a);

    return unit.compileModule(sexp, diag);
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
    defer parsed.deinit();

    var diagnostic = Diagnostic.init();
    if (compile(t.allocator, parsed, &diagnostic)) |result| {
        std.debug.print("wat:\n{s}\n", .{result.emitText()});
    } else |err| {
        std.debug.print("err {}:\n{}", .{ err, diagnostic });
    }
}
