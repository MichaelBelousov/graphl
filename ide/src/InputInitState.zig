const std = @import("std");

pub const InputInitState = union(enum) {
    node: struct { id: usize, out_pin: usize },
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    symbol: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, opts: std.json.ParseOptions) !@This() {
        if (.object_begin != try source.next()) return error.UnexpectedToken;
        // FIXME: don't accept things like { "int": 20, "float": 34.0 } => float{34.0}
        var value: @This() = undefined;
        while (true) {
            const token = try source.nextAlloc(allocator, opts.allocate.?);
            switch (token) {
                inline .string, .allocated_string => |k| {
                    if (std.mem.eql(u8, k, "node")) {
                        if (value != .node) value = .{ .node = undefined };
                        value.node.id = try std.json.innerParse(usize, allocator, source, opts);
                    } else if (std.mem.eql(u8, k, "outPin")) {
                        if (value != .node) value = .{ .node = undefined };
                        value.node.out_pin = try std.json.innerParse(usize, allocator, source, opts);
                    } else if (std.mem.eql(u8, k, "int")) {
                        value = .{ .int = try std.json.innerParse(i64, allocator, source, opts) };
                    } else if (std.mem.eql(u8, k, "float")) {
                        value = .{ .float = try std.json.innerParse(f64, allocator, source, opts) };
                    } else if (std.mem.eql(u8, k, "bool")) {
                        value = .{ .bool = try std.json.innerParse(bool, allocator, source, opts) };
                    } else if (std.mem.eql(u8, k, "string")) {
                        value = .{ .string = try std.json.innerParse([]const u8, allocator, source, opts) };
                    } else if (std.mem.eql(u8, k, "symbol")) {
                        value = .{ .symbol = try std.json.innerParse([]const u8, allocator, source, opts) };
                    } else {
                        return error.UnexpectedToken;
                    }
                },
                .object_end => break,
                else => unreachable,
            }
        }
        return value;
    }
};

test "parse InputInitState" {
    const result = try std.json.parseFromSlice([]const InputInitState, std.testing.allocator,
        \\[
        \\  {"id": 0, "outPin": 1},
        \\  {"int": -201},
        \\  {"float": 0.32},
        \\  {"bool": false},
        \\  {"bool": true},
        \\  {"string": "hello"},
        \\  {"symbol": "world"}
        \\]
    , .{});
    defer result.deinit();

    const expected = &[_]InputInitState{
        InputInitState{ .node = .{ .id = 0, .out_pin = 1 } },
        InputInitState{ .int = -201 },
        InputInitState{ .float = 0.32 },
        InputInitState{ .bool = false },
        InputInitState{ .bool = true },
        InputInitState{ .string = "hello" },
        InputInitState{ .symbol = "world" },
    };

    try std.testing.expectEqualDeep(expected, result.value);

    try std.testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(InputInitState, std.testing.allocator,
        \\{"int": "test"}
    , .{}));
}
