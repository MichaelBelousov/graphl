const std = @import("std");
const builtin = @import("builtin");
const FileBuffer = @import("./FileBuffer.zig");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const io = std.io;
const testing = std.testing;
const json = std.json;
const pool = &@import("./InternPool.zig").pool;

// FIXME: don't include in non-debug builds

fn _print_sexp(sexp: *const Sexp) callconv(.C) void {
    std.debug.print("{}\n", .{sexp});
}

comptime {
    if (builtin.target.cpu.arch != .wasm32 and builtin.mode == .Debug) {
        @export(&_print_sexp, .{ .name = "_print_sexp", .linkage = .strong });
    }
}

// consider making `.x` a special syntax which accesses .x from an object
pub const Sexp = struct {
    label: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    value: union(enum) {
        module: std.ArrayList(Sexp),
        list: std.ArrayList(Sexp),
        void,
        int: i64,
        float: f64,
        bool: bool,
        /// this Sexp owns the referenced memory, it must be freed
        ownedString: []const u8,
        /// this Sexp is borrowing the referenced memory, it should not be freed
        borrowedString: []const u8,
        /// always borrowed
        symbol: [:0]const u8,
        // TODO: quote/quasiquote, etc
    },

    const Self = @This();

    pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
        switch (self.value) {
            .ownedString => |v| alloc.free(v),
            .list, .module => |v| {
                for (v.items) |item| item.deinit(alloc);
                v.deinit();
            },
            .void, .int, .float, .bool, .borrowedString, .symbol => {},
        }
        // FIXME: labels are assumed to be leakable!
        // if (self.label) |l|
        //     alloc.free(l);
    }

    pub fn emptyList(alloc: std.mem.Allocator) Sexp {
        return Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
    }

    pub fn emptyListCapacity(alloc: std.mem.Allocator, capacity: usize) !Sexp {
        return Sexp{ .value = .{ .list = try std.ArrayList(Sexp).initCapacity(alloc, capacity) } };
    }

    pub fn symbol(sym: [:0]const u8) Sexp {
        return Sexp{ .value = .{ .symbol = pool.getSymbol(sym) } };
    }

    pub fn int(value: i64) Sexp {
        return Sexp{ .value = .{ .int = value } };
    }


    /// returns an empty Sexp module
    pub fn newModule(alloc: std.mem.Allocator) Sexp {
        return Sexp{ .value = .{ .module = std.ArrayList(Sexp).init(alloc) } };
    }

    pub fn toOwnedSlice(self: *Self) ![]Sexp {
        return switch (self.value) {
            .list, .module => |*v| v.toOwnedSlice(),
            .ownedString, .void, .int, .float, .bool, .borrowedString, .symbol => @panic("can only call toOwnedSlice on modules and lists"),
        };
    }

    const WriteState = struct {
        /// number of spaces we are in
        depth: usize = 0,
    };

    fn writeModule(form: std.ArrayList(Sexp), writer: anytype, state: WriteState, comptime opts: WriteOptions) @TypeOf(writer).Error!WriteState {
        for (form.items, 0..) |item, i| {
            if (i != 0) _ = try writer.write("\n");
            try writer.writeByteNTimes(' ', state.depth);
            _ = try item._write(writer, .{ .depth = state.depth }, opts);
        }

        return .{ .depth = 0 };
    }

    fn writeList(form: std.ArrayList(Sexp), writer: anytype, state: WriteState, comptime opts: WriteOptions) @TypeOf(writer).Error!WriteState {
        var depth: usize = 0;

        depth += try writer.write("(");

        if (form.items.len >= 1) {
            depth += (try form.items[0]._write(writer, .{ .depth = state.depth + depth }, opts)).depth;
        }

        if (form.items.len >= 2) {
            depth += try writer.write(" ");

            _ = try form.items[1]._write(writer, .{ .depth = state.depth + depth }, opts);

            for (form.items[2..]) |item| {
                _ = try writer.write("\n");
                try writer.writeByteNTimes(' ', state.depth + depth);
                _ = try item._write(writer, .{ .depth = state.depth + depth }, opts);
            }
        }

        _ = try writer.write(")");

        return .{ .depth = depth };
    }

    // eventually we want to format according to macro syntax
    const SpecialWriter = struct {
        pub fn @"if"(self: Self, writer: anytype, state: WriteState) @TypeOf(writer).Error!WriteState {
            _ = self;
            return state;
        }

        pub fn begin(self: Self, writer: anytype, state: WriteState) @TypeOf(writer).Error!WriteState {
            _ = self;
            return state;
        }
    };

    fn _write(self: Self, writer: anytype, state: WriteState, comptime opts: WriteOptions) @TypeOf(writer).Error!WriteState {
        // TODO: calculate stack space requirements?
        const write_state_or_err: @TypeOf(writer).Error!WriteState = switch (self.value) {
            .module => |v| writeModule(v, writer, state, opts),
            .list => |v| writeList(v, writer, state, opts),
            inline .float, .int => |v| _: {
                var counting_writer = std.io.countingWriter(writer);
                try counting_writer.writer().print("{d}", .{v});
                break :_ .{ .depth = @intCast(counting_writer.bytes_written) };
            },
            .bool => |v| _: {
                _ = try writer.write(if (v) syms.true.value.symbol else syms.false.value.symbol);
                std.debug.assert(syms.true.value.symbol.len == syms.false.value.symbol.len);
                break :_ .{ .depth = syms.true.value.symbol.len };
            },
            .void => _: {
                _ = try writer.write(syms.void.value.symbol);
                break :_ .{ .depth = syms.void.value.symbol.len };
            },
            .ownedString, .borrowedString => |v| _: {
                // able to specify via formating params
                var cw = std.io.countingWriter(writer);
                switch (opts.string_literal_dialect) {
                    .json => {
                        try json.encodeJsonString(v, .{}, cw.writer());
                    },
                    .simple => {
                        try cw.writer().writeByte('"');
                        for (v) |c| switch (c) {
                            '"' => try cw.writer().writeAll("\\\""),
                            else => try cw.writer().writeByte(c),
                        };
                        try cw.writer().writeByte('"');
                    },
                    // FIXME: use writeWatMemoryString?
                    .wat => {
                        try cw.writer().writeByte('"');
                        try cw.writer().writeAll(v);
                        try cw.writer().writeByte('"');
                    },
                }
                break :_ .{ .depth = @intCast(cw.bytes_written + 2) };
            },
            .symbol => |v| _: {
                try writer.print("{s}", .{v});
                break :_ .{ .depth = v.len };
            },
        };

        const write_state = try write_state_or_err;

        if (self.label) |label|
            _ = try writer.print(" {s}", .{label});

        return write_state;
    }

    const WriteOptions = struct {
        string_literal_dialect: enum {
            json,
            wat,
            // HACK: backslashes can't be escaped cuz this sucks. Temporary to make encoding
            // WAT easier
            /// only escape quotes, not even backslashes
            simple,
        } = .simple,
    };

    pub fn write(self: Self, writer: anytype, comptime options: WriteOptions) !usize {
        var counting_writer = std.io.countingWriter(writer);
        _ = try self._write(counting_writer.writer(), .{}, options);
        return @intCast(counting_writer.bytes_written);
    }

    pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        _ = try self._write(writer, .{}, .{});
    }

    pub fn recursive_eq(self: Self, other: Self) bool {
        if (std.meta.activeTag(self.value) != std.meta.activeTag(other.value))
            return false;

        if ((self.comment == null) != (other.comment == null))
            return false;

        if (!std.meta.eql(self.comment, other.comment))
            return false;

        if ((self.label == null) != (other.label == null))
            return false;

        if (self.label != null and other.label != null and !std.mem.eql(u8, self.label.?, other.label.?))
            return false;

        switch (self.value) {
            .float => |v| return v == other.value.float,
            .bool => |v| return v == other.value.bool,
            .void => return true,
            .int => |v| return v == other.value.int,
            .ownedString => |v| return std.mem.eql(u8, v, other.value.ownedString),
            .borrowedString => |v| return std.mem.eql(u8, v, other.value.borrowedString),
            .symbol => |v| return std.mem.eql(u8, v, other.value.symbol),
            inline .module, .list => |v, sexp_type| {
                const other_list = @field(other.value, @tagName(sexp_type));
                if (v.items.len != other_list.items.len) {
                    return false;
                }
                for (v.items, other_list.items) |item, other_item| {
                    if (!item.recursive_eq(other_item))
                        return false;
                }
                return true;
            },
        }
    }

    pub fn jsonValue(self: @This(), alloc: std.mem.Allocator) !json.Value {
        return switch (self.value) {
            .list => |v| _: {
                var result = json.Array.init(alloc);
                try result.ensureTotalCapacityPrecise(v.items.len);
                for (v.items) |item| {
                    (try result.addOne()).* = try item.jsonValue(alloc);
                }
                break :_ json.Value{ .array = result };
            },
            .module => |v| _: {
                var result = json.ObjectMap.init(alloc);
                // TODO: ensureTotalCapacityPrecise
                try result.put("module", try (Sexp{ .value = .{ .list = v } }).jsonValue(alloc));
                break :_ json.Value{ .object = result };
            },
            .float => |v| json.Value{ .float = v },
            .int => |v| json.Value{ .integer = v },
            .bool => |v| json.Value{ .bool = v },
            .void => .null,
            .ownedString => |v| json.Value{ .string = v },
            .borrowedString => |v| json.Value{ .string = v },
            .symbol => |v| _: {
                var result = json.ObjectMap.init(alloc);
                // TODO: ensureTotalCapacityPrecise
                try result.put("symbol", json.Value{ .string = v });
                break :_ json.Value{ .object = result };
            },
        };
    }
};

test "free sexp" {
    const alloc = std.testing.allocator;
    const str = Sexp{ .value = .{ .ownedString = try alloc.alloc(u8, 10) } };
    defer str.deinit(alloc);
}

test "write sexp" {
    var list = std.ArrayList(Sexp).init(std.testing.allocator);
    (try list.addOne()).* = Sexp{ .value = .{ .symbol = "hello" } };
    (try list.addOne()).* = Sexp{ .value = .{ .borrowedString = "world\"" } };
    (try list.addOne()).* = Sexp{ .value = .{ .float = 0.5 } };
    (try list.addOne()).* = Sexp{ .value = .{ .float = 1.0 } };
    defer list.deinit();
    var root_sexp = Sexp{ .value = .{ .list = list } };

    var buff: [1024]u8 = undefined;
    var fixed_buffer_stream = std.io.fixedBufferStream(&buff);
    const writer = fixed_buffer_stream.writer();

    const bytes_written = try root_sexp.write(writer, .{});

    try testing.expectEqualStrings(
        \\(hello "world\""
        \\       0.5
        \\       1)
    , buff[0..bytes_written]);
}

// TODO: move into the environment as known syms
pub const syms = struct {
    pub const meta = Sexp{ .value = .{ .symbol = "meta" } };
    pub const version = Sexp{ .value = .{ .symbol = "version" } };
    pub const import = Sexp{ .value = .{ .symbol = "import" } };
    pub const define = Sexp{ .value = .{ .symbol = "define" } };
    pub const typeof = Sexp{ .value = .{ .symbol = "typeof" } };
    pub const as = Sexp{ .value = .{ .symbol = "as" } };
    pub const begin = Sexp{ .value = .{ .symbol = "begin" } };
    pub const @"return" = Sexp{ .value = .{ .symbol = "return" } };
    // FIXME: is this really a symbol?
    pub const @"true" = Sexp{ .value = .{ .symbol = "#t" } };
    pub const @"false" = Sexp{ .value = .{ .symbol = "#f" } };
    pub const @"void" = Sexp{ .value = .{ .symbol = "#void" } };
    pub const quote = Sexp{ .value = .{ .symbol = "_quote" } }; // FIXME: currently json_quote is quote lol
    pub const hard_quote = Sexp{ .value = .{ .symbol = "hardquote" } };

    const builtin_nodes = @import("./nodes/builtin.zig").builtin_nodes;

    pub const @"+" = Sexp{ .value = .{ .symbol = builtin_nodes.@"+".name() } };
    pub const @"-" = Sexp{ .value = .{ .symbol = builtin_nodes.@"-".name() } };
    pub const @"*" = Sexp{ .value = .{ .symbol = builtin_nodes.@"*".name() } };
    pub const @"/" = Sexp{ .value = .{ .symbol = builtin_nodes.@"/".name() } };
    pub const @"==" = Sexp{ .value = .{ .symbol = builtin_nodes.@"==".name() } };
    pub const @"!=" = Sexp{ .value = .{ .symbol = builtin_nodes.@"!=".name() } };
    pub const @"<=" = Sexp{ .value = .{ .symbol = builtin_nodes.@"<=".name() } };
    pub const @"<" = Sexp{ .value = .{ .symbol = builtin_nodes.@"<".name() } };
    pub const @">" = Sexp{ .value = .{ .symbol = builtin_nodes.@">".name() } };
    pub const @">=" = Sexp{ .value = .{ .symbol = builtin_nodes.@">=".name() } };
    pub const not = Sexp{ .value = .{ .symbol = builtin_nodes.not.name() } };
    pub const @"and" = Sexp{ .value = .{ .symbol = builtin_nodes.@"and".name() } };
    pub const @"or" = Sexp{ .value = .{ .symbol = builtin_nodes.@"or".name() } };

    pub const @"if" = Sexp{ .value = .{ .symbol = builtin_nodes.@"if".name() } };
    pub const @"set!" = Sexp{ .value = .{ .symbol = builtin_nodes.@"set!".name() } };

    pub const min = Sexp{ .value = .{ .symbol = builtin_nodes.min.name() } };
    pub const max = Sexp{ .value = .{ .symbol = builtin_nodes.max.name() } };
    pub const string_indexof = Sexp{ .value = .{ .symbol = builtin_nodes.string_indexof.name() } };
    pub const string_length = Sexp{ .value = .{ .symbol = builtin_nodes.string_length.name() } };
    pub const string_equal = Sexp{ .value = .{ .symbol = builtin_nodes.string_equal.name() } };
    pub const string_join = Sexp{ .value = .{ .symbol = builtin_nodes.string_concat.name() } };

    // TODO: add a test that all builtin nodes are covered here...
    pub const make_vec3 = Sexp{ .value = .{ .symbol = builtin_nodes.make_vec3.name() } };
    pub const vec3_x = Sexp{ .value = .{ .symbol = builtin_nodes.vec3_x.name() } };
    pub const vec3_y = Sexp{ .value = .{ .symbol = builtin_nodes.vec3_y.name() } };
    pub const vec3_z = Sexp{ .value = .{ .symbol = builtin_nodes.vec3_z.name() } };

    pub const make_rgba = Sexp{ .value = .{ .symbol = builtin_nodes.make_rgba.name() } };
    pub const rgba_r = Sexp{ .value = .{ .symbol = builtin_nodes.rgba_r.name() } };
    pub const rgba_g = Sexp{ .value = .{ .symbol = builtin_nodes.rgba_g.name() } };
    pub const rgba_b = Sexp{ .value = .{ .symbol = builtin_nodes.rgba_b.name() } };
    pub const rgba_a = Sexp{ .value = .{ .symbol = builtin_nodes.rgba_a.name() } };

    pub const make_symbol = Sexp{ .value = .{ .symbol = builtin_nodes.make_symbol.name() } };
    pub const make_string = Sexp{ .value = .{ .symbol = builtin_nodes.make_string.name() } };

    pub const json_quote = Sexp{ .value = .{ .symbol = builtin_nodes.json_quote.name() } };
};

pub const primitive_type_syms = struct {
    pub const @"i32" = Sexp{ .value = .{ .symbol = "i32" } };
    pub const @"i64" = Sexp{ .value = .{ .symbol = "i64" } };
    pub const @"u32" = Sexp{ .value = .{ .symbol = "u32" } };
    pub const @"u64" = Sexp{ .value = .{ .symbol = "u64" } };
    pub const @"f32" = Sexp{ .value = .{ .symbol = "f32" } };
    pub const @"f64" = Sexp{ .value = .{ .symbol = "f64" } };
};

pub fn writeWatMemoryString(data: []const u8, writer: anytype) !void {
    for (data) |char| {
        switch (char) {
            '\\' => {
                try writer.writeAll("\\\\");
            },
            // printable ascii not including '\\' or '"'
            ' '...'"' - 1, '"' + 1...'\\' - 1, '\\' + 1...127 => {
                try writer.writeByte(char);
            },
            // FIXME: use ascii bit magic/table here, I'm too lazy and time pressed
            else => {
                try writer.writeByte('\\');
                try std.fmt.formatInt(char, 16, .lower, .{ .width = 2, .fill = '0' }, writer);
            },
        }
    }
}
