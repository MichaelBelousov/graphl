const std = @import("std");

pub const InputInitState = union(enum) {
    node: struct { id: usize, out_pin: usize },
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    symbol: [:0]const u8,

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
                        value = .{ .symbol = try std.json.innerParse([:0]const u8, allocator, source, opts) };
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

    pub fn jsonStringify(self: *const @This(), jws: anytype) !void {
        try switch (self.*) {
            .node => |v| jws.write(struct { node: usize, outPin: usize, }{ .node =  v.id, .outPin = v.out_pin}),
            .int => |v| jws.write(struct {int: i64}{.int = v}),
            .float => |v| jws.write(struct {float: f64}{.float = v}),
            .bool => |v| jws.write(struct {bool: bool}{.bool = v}),
            .string => |v| jws.write(struct {string: []const u8}{.string = v}),
            .symbol => |v| jws.write(struct {symbol: [:0]const u8}{.symbol = v}),
        };
    }
};

test "InputInitState twoway" {
    const src =
        \\[
        \\  {
        \\    "node": 0,
        \\    "outPin": 1
        \\  },
        \\  {
        \\    "int": -201
        \\  },
        \\  {
        \\    "float": 3.2e-1
        \\  },
        \\  {
        \\    "bool": false
        \\  },
        \\  {
        \\    "bool": true
        \\  },
        \\  {
        \\    "string": "hello"
        \\  },
        \\  {
        \\    "symbol": "world"
        \\  }
        \\]
    ;

    const parse_result = try std.json.parseFromSlice([]const InputInitState, std.testing.allocator, src, .{});
    defer parse_result.deinit();

    const objects = &[_]InputInitState{
        InputInitState{ .node = .{ .id = 0, .out_pin = 1 } },
        InputInitState{ .int = -201 },
        InputInitState{ .float = 0.32 },
        InputInitState{ .bool = false },
        InputInitState{ .bool = true },
        InputInitState{ .string = "hello" },
        InputInitState{ .symbol = "world" },
    };

    try std.testing.expectEqualDeep(objects, parse_result.value);

    const stringify_result = try std.json.stringifyAlloc(std.testing.allocator, objects, .{.whitespace = .indent_2});
    defer std.testing.allocator.free(stringify_result);

    try std.testing.expectEqualStrings(src, stringify_result);

    try std.testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(InputInitState, std.testing.allocator,
        \\{"int": "test"}
    , .{}));
}
