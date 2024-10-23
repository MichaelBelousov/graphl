const std = @import("std");
const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;
// TODO: create a build.zig for binaryen
const c = @cImport({
    //@cDefine();
    @cInclude("../../binaryen/src/binaryen-c.h");
});

pub const Diagnostic = struct {
    err: Error,

    // context
    module: *const Sexp,

    const Error = union(enum(@sizeOf(anyerror))) {
        None: void = 0,
        BadTopLevelForm: *const Sexp = 1,
    };

    const Code = error {
        badTopLevelForm,
    };

    pub fn init(module: *const Sexp) @This() {
        std.debug.assert(module.value == .module);
        return @This(){
            .err = .None,
            .module = module,
        };
    }
};

pub fn compileFunc(wasm_module: c.BinaryenModule, sexp: *const Sexp) void {
    std.debug.assert(sexp.value == .list);
    std.debug.assert(sexp.value.list.items.len >= 1);
    std.debug.assert(sexp.value.list.items[0].value == .symbol);
    std.debug.assert(sexp.value.list.items[0].value.symbol == syms.define);
    std.debug.assert(sexp.value.list.items[1].value == .list);
    std.debug.assert(sexp.value.list.items[1].value.list.items.len >= 1);
    for (sexp.value.list.items[1].value.list.items) |*def_item| {
        // function argument names must be symbols
        std.debug.assert(def_item.value == .symbol);
    }

    const func_name = sexp.value.list.items[1].value.list.items[0].value.symbol;
    const args = sexp.value.list.items[1].value.list.items[1..];

    const wasm_func = c.BinaryenAddFunction(wasm_module, func_name, params, results, null, 0, add);
}

pub fn compileTypeOf(wasm_module: c.BinaryenModule, sexp: *const Sexp) void {
    std.debug.assert(sexp.value == .list);
    std.debug.assert(sexp.value.list.items.len >= 1);
    std.debug.assert(sexp.value.list.items[0].value == .symbol);
    std.debug.assert(sexp.value.list.items[0].value.symbol == syms.typeof);
    std.debug.assert(sexp.value.list.items[1].value == .list);
    std.debug.assert(sexp.value.list.items[1].value.list.items.len >= 1);
    for (sexp.value.list.items[1].value.list.items) |*def_item| {
        // function argument names must be symbols
        std.debug.assert(def_item.value == .symbol);
    }

    const func_name = sexp.value.list.items[1].value.list.items[0].value.symbol;
    const args = sexp.value.list.items[1].value.list.items[1..];
}

fn compileInternal(sexp: *Sexp, wasm_module: c.BinaryenModule, _in_diagnostic: *Diagnostic) void {

}

pub fn compile(sexp: *const Sexp, _in_diagnostic: ?*Diagnostic) void {
    const wasm_module = c.BinaryenModuleCreate();

    var ignored_diagnostic: Diagnostic = undefined; // FIXME: why don't we init?
    const diag = if (_in_diagnostic) |d| d else &ignored_diagnostic;

    diag.module = sexp;

    std.debug.assert(sexp.value == .module);

    for (sexp.value.module.items) |decl| {
        switch (decl.value) {
            .list => |forms| {
                for (forms.items) |form| {
                    compileInternal(form, wasm_module, diag);
                }
            },
            else => |other| {
                diag.err = Diagnostic.Error{ .BadTopLevelForm = other };
            },
        }
    }


    const ii: [2]c.BinaryenType = [_]c.BinaryenType{c.BinaryenTypeInt32(), c.BinaryenTypeInt32()};
    const params: c.BinaryenType = c.BinaryenTypeCreate(ii, 2);
    const results: c.BinaryenType = c.BinaryenTypeInt32();

    // Get the 0 and 1 arguments, and add them
    const x = c.BinaryenLocalGet(wasm_module, 0, c.BinaryenTypeInt32());
    const y = c.BinaryenLocalGet(wasm_module, 1, c.BinaryenTypeInt32());
    const add = c.BinaryenBinary(wasm_module, c.BinaryenAddInt32(), x, y);

    // Create the add function
    // Note: no additional local variables
    // Note: no basic blocks here, we are an AST. The function body is just an
    // expression node.
    const adder = c.BinaryenAddFunction(wasm_module, "adder", params, results, null, 0, add);
    _ = adder;

    // Print it out
    c.BinaryenModulePrint(wasm_module);

    // Clean up the module, which owns all the objects we created above
    c.BinaryenModuleDispose(wasm_module);
}
