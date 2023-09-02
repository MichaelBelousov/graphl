const std = @import("std");
const builtin = @import("builtin");
const FileBuffer = @import("./FileBuffer.zig");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const io = std.io;
const testing = std.testing;
const json = std.json;

pub const Sexp = union(enum) {
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

    const Self = @This();

    pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
        switch (self) {
            .ownedString => |v| alloc.free(v),
            .list => |v| {
                for (v.items) |item| item.deinit(alloc);
                v.deinit();
            },
            else => {},
        }
    }

    const WriteState = struct {
        indent_level: usize = 0,
    };

    // explicit Error works around https://github.com/ziglang/zig/issues/2971
    fn _write(self: Self, writer: anytype, state: WriteState) @TypeOf(writer).Error!void {
        // TODO: calculate stack space requirements?
        switch (self) {
            .list => |v| {
                _ = try writer.write("(");
                for (v.items, 0..) |item, i| {
                    if (i != 0) {
                        try writer.writeByteNTimes(' ', (state.indent_level + 1) * 2);
                    }
                    _ = try item._write(writer, .{ .indent_level = state.indent_level + 1});
                    if (i != v.items.len - 1)
                        // need like a counting writer to know how long lines will be
                        _ = try writer.write("\n");
                }
                _ = try writer.write(")");
            },
            // FIXME: the bytecounts here are ignored!
            .float => |v| try writer.print("{d}", .{v}),
            .bool => |v| { _ = try writer.write(if (v) "#t" else "#f"); },
            .void => { _ = try writer.write("#void"); },
            .int => |v| try writer.print("{d}", .{v}),
            .ownedString, .borrowedString => |v| try writer.print("\"{s}\"", .{v}),
            .symbol => |v| try writer.print("{s}", .{v}),
        }
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
        if (std.meta.activeTag(self) != std.meta.activeTag(other))
            return false;

        switch (self) {
            .list => |v| {
                if (v.items.len != other.list.items.len)
                    return false;
                for (v.items, 0..) |item, i| {
                    const other_item = other.list.items[i];
                    if (!item.recursive_eq(other_item))
                        return false;
                }
                return true;
            },
            .float => |v| return v == other.float,
            .bool => |v| return v == other.bool,
            .void => return true,
            .int => |v| return v == other.int,
            .ownedString => |v| return std.mem.eql(u8, v, other.ownedString),
            .borrowedString => |v| return std.mem.eql(u8, v, other.borrowedString),
            .symbol => |v| return std.mem.eql(u8, v, other.symbol),
        }
    }

    pub fn jsonValue(self: @This(), alloc: std.mem.Allocator) !json.Value {
        return switch (self) {
            .list => |v| _: {
                var result = json.Array.init(alloc);
                try result.ensureTotalCapacityPrecise(v.items.len);
                for (v.items) |item| {
                    (try result.addOne()).* = try item.jsonValue(alloc);
                }
                break :_ json.Value{ .array = result };
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
    const str = Sexp{ .ownedString = try alloc.alloc(u8, 10) };
    defer str.deinit(alloc);
}

test "write sexp" {
    var list = std.ArrayList(Sexp).init(std.testing.allocator);
    (try list.addOne()).* = Sexp{ .symbol = "hello" };
    (try list.addOne()).* = Sexp{ .float = 0.5 };
    defer list.deinit();
    var root_sexp = Sexp{ .list = list };

    var buff: [1024]u8 = undefined;
    var fixed_buffer_stream = std.io.fixedBufferStream(&buff);
    var writer = fixed_buffer_stream.writer();

    const bytes_written = try root_sexp.write(writer);

    try testing.expectEqualStrings(
        \\(hello
        \\  0.5)
    , buff[0..bytes_written]);
}

pub const syms = struct {
    pub const import = Sexp{ .symbol = "import" };
    pub const define = Sexp{ .symbol = "define" };
    pub const as = Sexp{ .symbol = "as" };
    // FIXME: is this really a symbol?
    pub const @"true" = Sexp{ .symbol = "#t" };
    pub const @"false" = Sexp{ .symbol = "#f" };
};
