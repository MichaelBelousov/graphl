const std = @import("std");
const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;
const builtin = @import("./nodes/builtin.zig");

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
    // TODO: use interning!
    typeof_map: std.StringHashMapUnmanaged(builtin.Type),

    pub fn init() !@This() {
        return .{
            .typeof_map = .{},
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.typeof_map.deinit(alloc);
    }

    pub fn compileFunc(self: *@This(), sexp: *const Sexp, writer: anytype, diag: *Diagnostic) !void {
        _ = self;
        _ = diag;

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
        const func_name_mangled = func_name;

        // TODO: search for types first
        // const type_info = self.typeof_map.getPtr(func_name) orelse error.NoSuchType;
        // if (type_info != .@"fn") {
        //     // TODO: fill diagnostic here
        //     return error.FuncBadType;
        // }

        try writer.print(
            \\(type $type_{0s} (func (param i32 i32) (result i32)))
            \\(func ${0s} (export "{0s}") 
        , .{func_name_mangled});
        // for (params, type_info.@"fn".params, 0..) |p, ptype, i| {
        //     try writer.print("(param ${s}{} {s}) ", .{ p.value.symbol, i, ptype.name });
        // }
        // TODO: get locals count
        const locals = [_][]const u8{};
        for (locals) |l| {
            try writer.print("()", .{l});
        }
        const result_type = "i32"; // FIXME
        try writer.print("(result ${s})", .{result_type});
    }

    pub fn compileTypeOf(writer: anytype, sexp: *const Sexp) void {
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

        // FIXME: wrong
        _ = try writer.write(
            \\(type (;0;) (func (param i32 i32)))
        );
    }

    pub fn compileModule(self: *@This(), sexp: *const Sexp, writer: anytype, diag: *Diagnostic) !void {
        std.debug.assert(sexp.value == .module);

        _ = try writer.write(
            \\(module
            \\
        );

        for (sexp.value.module.items) |decl| {
            switch (decl.value) {
                .list => |forms| {
                    for (forms.items) |*form| {
                        // TODO: aggregate errors
                        self.compileFunc(form, writer, diag) catch continue;
                    }
                },
                else => {
                    diag.err = Diagnostic.Error{ .BadTopLevelForm = &decl };
                },
            }
        }

        _ = try writer.write(")");
    }
};

pub fn compile(a: std.mem.Allocator, sexp: *const Sexp, writer: anytype, _in_diagnostic: ?*Diagnostic) !void {
    var unit = try Compilation.init();
    defer unit.deinit(a);

    var ignored_diagnostic: Diagnostic = undefined; // FIXME: why don't we init?
    const diag = if (_in_diagnostic) |d| d else &ignored_diagnostic;
    diag.module = sexp;

    return unit.compileModule(sexp, writer, diag);
}
