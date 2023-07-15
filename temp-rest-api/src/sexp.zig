const std = @import("std");
const builtin = @import("builtin");
const FileBuffer = @import("./FileBuffer.zig");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const io = std.io;
const testing = std.testing;
const json = std.json;

pub const Sexp = union (enum) {
    call: struct {
        callee: *const Sexp,
        args: std.ArrayList(Sexp),
    },
    int: i64,
    float: f64,
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
            .call => |v| v.args.deinit(),
            else => {},
        }
    }

    pub fn write(self: Self, writer: anytype) !usize {
        var total_bytes_written: usize = 0;
        switch (self) {
            .call => |v| {
                total_bytes_written += try writer.write("(");
                total_bytes_written += try v.callee.write(writer);
                if (v.args.items.len > 0)
                    total_bytes_written += try writer.write(" ");
                for (v.args.items) |arg, i| {
                    total_bytes_written += try arg.write(writer);
                    if (i != v.args.items.len - 1)
                        total_bytes_written += try writer.write(" ");
                }
                total_bytes_written += try writer.write(")");
            },
            // FIXME: the bytecounts here are ignored!
            .float => |v| try std.fmt.format(writer, "{d}", .{v}),
            .int => |v| try std.fmt.format(writer, "{d}", .{v}),
            .ownedString, .borrowedString => |v| try std.fmt.format(writer, "\"{s}\"", .{v}),
            .symbol => |v| try std.fmt.format(writer, "{s}", .{v}),
        }
        return total_bytes_written;
    }
};

test "free sexp" {
    const alloc = std.testing.allocator;
    const str = Sexp{.ownedString = try alloc.alloc(u8, 10)};
    defer str.deinit(alloc);
}

test "write sexp" {
    var root_args = std.ArrayList(Sexp).init(std.testing.allocator);
    const arg1 = try root_args.addOne();
    arg1.* = Sexp{.float = 0.5};
    defer root_args.deinit();
    var root_sexp = Sexp{.call = .{
        .callee=&Sexp{.symbol="hello"},
        .args=root_args,
    }};

    var buff: [1024]u8 = undefined;
    var fixedBufferStream = std.io.fixedBufferStream(&buff);
    var writer = fixedBufferStream.writer();

    _ = try root_sexp.write(writer);

    try testing.expectEqualStrings(
        \\(hello 0.5)
        ,
        buff[0..11] // not using result of write because it is currently wrong
    );
}

pub const syms = struct {
    pub const import = Sexp{.symbol = "import"};
    pub const define = Sexp{.symbol = "define"};
    pub const as = Sexp{.symbol = "as"};
    pub const VOID = Sexp{.symbol = "__VOID__"};
};

