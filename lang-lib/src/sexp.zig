const std = @import("std");
const builtin = @import("builtin");
const FileBuffer = @import("./FileBuffer.zig");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const io = std.io;
const testing = std.testing;
const json = std.json;

pub const Sexp = struct {
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
        symbol: []const u8,
        // TODO: quote/quasiquote, etc
    },

    const Self = @This();

    pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
        switch (self.value) {
            .ownedString => |v| alloc.free(v),
            .list => |v| {
                for (v.items) |item| item.deinit(alloc);
                v.deinit();
            },
            else => {},
        }
    }

    const WriteState = struct {
        /// number of spaces we are in
        depth: usize = 0,
    };

    fn genericWriteForm(form: std.ArrayList(Sexp), writer: anytype, state: WriteState, with_parens: bool) @TypeOf(writer).Error!WriteState {
        var depth: usize = 0;

        if (with_parens)
            depth += try writer.write("(");

        if (form.items.len >= 1) {
            depth += (try form.items[0]._write(writer, .{ .depth = state.depth + depth })).depth;
        }

        if (form.items.len >= 2) {
            depth += try writer.write(" ");

            _ = try form.items[1]._write(writer, .{ .depth = state.depth + depth });

            for (form.items[2..]) |item| {
                _ = try writer.write("\n");
                try writer.writeByteNTimes(' ', state.depth + depth);
                _ = try item._write(writer, .{ .depth = state.depth + depth });
            }
        }

        if (with_parens)
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

    fn _write(self: Self, writer: anytype, state: WriteState) @TypeOf(writer).Error!WriteState {
        // TODO: calculate stack space requirements?
        return switch (self.value) {
            .module => |v| genericWriteForm(v, writer, state, false),
            .list => |v| genericWriteForm(v, writer, state, true),
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
                _ = try writer.write(syms.true.value.symbol);
                break :_ .{ .depth = syms.true.value.symbol.len };
            },
            .ownedString, .borrowedString => |v| _: {
                // FIXME: this obviously doesn't handle characters that need escaping
                try writer.print("\"{s}\"", .{v});
                break :_ .{ .depth = v.len + 2 };
            },
            .symbol => |v| _: {
                try writer.print("{s}", .{v});
                break :_ .{ .depth = v.len };
            },
        };
    }

    pub fn write(self: Self, writer: anytype) !usize {
        var counting_writer = std.io.countingWriter(writer);
        _ = try self._write(counting_writer.writer(), .{});
        return @intCast(counting_writer.bytes_written);
    }

    pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        _ = try self._write(writer, .{});
    }

    pub fn recursive_eq(self: Self, other: Self) bool {
        if (std.meta.activeTag(self.value) != std.meta.activeTag(other.value))
            return false;

        if ((self.comment == null) != (other.comment == null))
            return false;

        if (!std.meta.eql(self.comment, other.comment))
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
                if (v.items.len != other_list.items.len)
                    return false;
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
    (try list.addOne()).* = Sexp{ .value = .{ .float = 0.5 } };
    (try list.addOne()).* = Sexp{ .value = .{ .float = 1.0 } };
    defer list.deinit();
    var root_sexp = Sexp{ .value = .{ .list = list } };

    var buff: [1024]u8 = undefined;
    var fixed_buffer_stream = std.io.fixedBufferStream(&buff);
    const writer = fixed_buffer_stream.writer();

    const bytes_written = try root_sexp.write(writer);

    try testing.expectEqualStrings(
        \\(hello 0.5
        \\       1)
    , buff[0..bytes_written]);
}

// TODO: move into the environment as known syms
pub const syms = struct {
    pub const import = Sexp{ .value = .{ .symbol = "import" } };
    pub const define = Sexp{ .value = .{ .symbol = "define" } };
    pub const typeof = Sexp{ .value = .{ .symbol = "typeof" } };
    pub const as = Sexp{ .value = .{ .symbol = "as" } };
    pub const begin = Sexp{ .value = .{ .symbol = "begin" } };
    // FIXME: is this really a symbol?
    pub const @"true" = Sexp{ .value = .{ .symbol = "#t" } };
    pub const @"false" = Sexp{ .value = .{ .symbol = "#f" } };
    pub const @"void" = Sexp{ .value = .{ .symbol = "#void" } };
};
