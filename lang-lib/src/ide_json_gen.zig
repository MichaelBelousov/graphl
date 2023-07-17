//! Generates json node definitions for the IDE prototype
//! Given a set of input Lisp files

const std = @import("std");
const builtin = @import("builtin");
const json = std.json;

const Parser = @import("./sexp_parser.zig").Parser;
const FileBuffer = @import("./FileBuffer.zig");

const Sexp = @import("./sexp.zig").Sexp;
const syms = @import("./sexp.zig").syms;

const Input = struct {
    label: []const u8,
    type: []const u8,
    default: ?json.Value = null,

    fn emitJson(self: @This(), stream: anytype) !void {
        try stream.beginObject();
        try stream.objectField("label");
        try stream.emitString(self.label);
        try stream.objectField("type");
        try stream.emitString(self.type);
        if (self.default) |default| {
            try stream.objectField("default");
            try stream.emitJson(default);
        }
        try stream.endObject();
    }
};

const Output = struct {
    label: []const u8,
    type: []const u8,

    fn emitJson(self: @This(), stream: anytype) !void {
        try stream.beginObject();
        try stream.objectField("label");
        try stream.emitString(self.label);
        try stream.objectField("type");
        try stream.emitString(self.type);
        try stream.endObject();
    }
};

const NodeDef = struct {
    id: []const u8,
    def: struct {
        label: []const u8,
        inputs: []const Input,
        outputs: []const Output,
    },

    // TODO: use new json utils in zig 0.11.0 to generate this...
    fn emitJson(self: @This(), stream: anytype) !void {
        try stream.beginObject();
        try stream.objectField("id");
        try stream.emitString(self.id);
        try stream.objectField("def");
        self.emitDef();
        try stream.endObject();
    }

    fn emitDef(self: @This(), stream: anytype) !void {
        try stream.beginObject();
        try stream.objectField("label");
        try stream.emitString(self.def.label);
        try stream.objectField("inputs");
        {
            try stream.beginArray();
            for (self.def.inputs) |input| {
                try stream.arrayElem();
                try input.emitJson(stream);
            }
            try stream.endArray();
        }
        try stream.objectField("outputs");
        {
            try stream.beginArray();
            for (self.def.outputs) |output| {
                try stream.arrayElem();
                try output.emitJson(stream);
            }
            try stream.endArray();
        }
        try stream.endObject();
    }
};

fn readDefineFuncPrototype(alloc: std.mem.Allocator, defined: Sexp) !?NodeDef {
    if (defined != .list)
        return null;
    if (defined.list.items.len < 1)
        return null;
    if (defined.list.items[0] != .symbol) {
        if (builtin.os.tag != .freestanding)
            std.debug.print("prototype name not a symbol", .{});
        return null;
    }

    const name = defined.list.items[0].symbol;

    // FIXME: add deinit to the NodeDef type
    var inputs = std.ArrayList(Input).init(alloc);
    errdefer inputs.deinit();
    try inputs.ensureTotalCapacityPrecise(defined.list.items.len - 1);

    for (defined.list.items[1..]) |arg| {
        switch (arg) {
            // FIXME: this is a simplification of what should actually happen...
            // (i32 x) is a real macro that returns a typed slot...
            .symbol => |v| (try inputs.addOne()).* = .{ .label = v, .type = "T" }, // FIXME: unevaled type
            .list => |v| {
                if (v.items.len < 2)
                    std.debug.panic("unsupported type syntax: {s}", .{name});
                if (v.items[0] != .symbol)
                    std.debug.panic("unsupported type syntax type: {s}", .{name});
                if (v.items[1] != .symbol)
                    std.debug.panic("unsupported type syntax name: {s}", .{name});
                (try inputs.addOne()).* = .{
                    .label = v.items[1].symbol,
                    .type = v.items[0].symbol,
                    .default = if (v.items.len >= 3) try v.items[2].jsonValue(alloc) else null,
                };
            },
            else => {
                // FIXME: should return error
                if (builtin.os.tag != .freestanding)
                    std.debug.print("non-list/symbol binding def\n", .{});
                return null;
            }
        }
    }

    // need to evaluate to know the type
    var outputs = std.ArrayList(Output).init(alloc);
    errdefer outputs.deinit();
    // NOTE: how do we determine if something is pure? contains no "set!"?
    try outputs.ensureTotalCapacityPrecise(1); // for now one

    // FIXME: this is completely fake, we need to evaluate (the types of the definition expression)
    // to get the result type
    (try outputs.addOne()).* =
        if (inputs.items.len >= 1) .{ .label = inputs.items[0].label, .type = inputs.items[0].type }
        else .{ .label = "next", .type = "exec" };

    return NodeDef{
        .id = name,
        .def = .{
            .label = name,
            // FIXME: directly include the array list otherwise leak
            .inputs = inputs.items,
            .outputs = outputs.items,
        }
    };
}

fn readDefineVarPrototype(alloc: std.mem.Allocator, defined: Sexp) !?NodeDef {
    if (defined != .symbol)
        return null;

    const name = defined.symbol;

    return NodeDef{
        .id = name,
        .def = .{
            .label = try std.fmt.allocPrint(alloc, "get_{s}", .{name}),
            .inputs = &.{},
            .outputs = &.{
                .{ .label = "get", .type = "T" } // FIXME: stub
            },
        },
    };
}

fn readDefine(alloc: std.mem.Allocator, defined: Sexp) !?NodeDef {
    return try readDefineVarPrototype(alloc, defined)
    orelse try readDefineFuncPrototype(alloc, defined);
}

/// NOTE: this does not yet expand macros to find top-level defines
pub fn readTopLevelExpr(alloc: std.mem.Allocator, expr: Sexp) !?NodeDef {
    if (expr != .list)
        return null;

    if (expr.list.items.len < 2)
        return null;

    // NOTE: this is temporary! if we do real macros, we must
    // evaluate a file to get all of its definitions
    const first = expr.list.items[0];
    const second = expr.list.items[1];

    if (first != .symbol)
        return null;

    if (std.mem.eql(u8, first.symbol, "define"))
        return readDefine(alloc, second);
    // if (std.mem.eql(u8, first.symbol, "define-macro"))
    //     //return readDefineMacro(second);
    //     unreachable;
    // if (std.mem.eql(u8, first.symbol, "define-c-struct")) 
    //     unreachable;
    // if (std.mem.eql(u8, first.symbol, "define-c-opaque")) 
    //     unreachable;
    // if (std.mem.eql(u8, first.symbol, "define-c-enum")) 
    //     unreachable;

    return null;
}

pub fn readSrc(alloc: std.mem.Allocator, src: []const u8, writer: anytype) !void {
    const parse_result = Parser.parse(alloc, src);

    if (parse_result == .err) {
        if (builtin.os.tag != .freestanding)
            std.debug.print("error reading:\n{}\n", .{parse_result.err});
        return error.ParseError;
    }

    var write_stream = json.writeStream(writer, 6);
    try write_stream.beginObject();


    for (parse_result.ok.items) |expr| {
        const maybe_node = try readTopLevelExpr(alloc, expr);
        if (maybe_node) |node| {
            try write_stream.objectField(node.id);
            try node.emitDef(&write_stream);
        }
    }

    try write_stream.endObject();
    _ = try writer.write("\n");
}

// pub fn main() !void {
//     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//     defer arena.deinit();
//     const alloc = arena.allocator();

//     var args_iter = std.process.args();
//     _ = args_iter.next(); // skip first arg since it is our own program

//     while (args_iter.next()) |arg| {
//         if (std.os.getenv("DEBUG") != null)
//             std.debug.print("input_file: {s}\n", .{arg});

//         const file = try FileBuffer.fromDirAndPath(alloc, std.fs.cwd(), arg);
//         defer file.free(alloc);

//         const stdout_writer = std.io.getStdOut().writer();
//         readSrc(alloc, file.buffer, stdout_writer)
//             catch continue;
//     }
// }

