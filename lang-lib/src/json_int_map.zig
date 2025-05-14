const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const ParseOptions = json.ParseOptions;
const innerParse = json.innerParse;
const innerParseFromValue = json.innerParseFromValue;
const Value = json.Value;

/// copied from std.json.ArrayHashMap
pub fn IntArrayHashMap(comptime Key: type, comptime T: type, comptime base: u8) type {
    return struct {
        map: std.AutoArrayHashMapUnmanaged(Key, T) = .{},

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.map.deinit(allocator);
        }

        pub fn jsonParse(allocator: Allocator, source: anytype, options: json.ParseOptions) !@This() {
            var map = std.AutoArrayHashMapUnmanaged(Key, T){};
            errdefer map.deinit(allocator);

            if (.object_begin != try source.next()) return error.UnexpectedToken;
            while (true) {
                const token = try source.nextAlloc(allocator, options.allocate.?);
                switch (token) {
                    inline .string, .allocated_string => |k| {
                        const int = try std.fmt.parseInt(Key, k, base);
                        const gop = try map.getOrPut(allocator, int);
                        if (gop.found_existing) {
                            switch (options.duplicate_field_behavior) {
                                .use_first => {
                                    // Parse and ignore the redundant value.
                                    // We don't want to skip the value, because we want type checking.
                                    _ = try innerParse(T, allocator, source, options);
                                    continue;
                                },
                                .@"error" => return error.DuplicateField,
                                .use_last => {},
                            }
                        }
                        gop.value_ptr.* = try innerParse(T, allocator, source, options);
                    },
                    .object_end => break,
                    else => unreachable,
                }
            }
            return .{ .map = map };
        }

        pub fn jsonParseFromValue(allocator: Allocator, source: Value, options: ParseOptions) !@This() {
            if (source != .object) return error.UnexpectedToken;

            var map = std.AutoArrayHashMapUnmanaged(Key, T){};
            errdefer map.deinit(allocator);

            var it = source.object.iterator();
            while (it.next()) |kv| {
                const k = kv.key_ptr.*;
                const int = try std.fmt.parseInt(Key, k, base);
                try map.put(allocator, int, try innerParseFromValue(T, allocator, kv.value_ptr.*, options));
            }
            return .{ .map = map };
        }

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            const intBuf: [32]u8 = undefined; // TODO: generate buff size from base
            try jws.beginObject();
            var it = self.map.iterator();
            while (it.next()) |kv| {
                const str = try std.fmt.bufPrint(&intBuf, "{s}", kv.key_ptr.*);
                try jws.objectField(str);
                try jws.write(kv.value_ptr.*);
            }
            try jws.endObject();
        }
    };
}

// test "parse JsonIntMap u16" {
//     const input =
//         \\{
//         \\  "id": 1031201,
//         \\  "type": "+",
//         \\  "inputs": {
//         \\    "0": {"id": 0, "outPin": 1},
//         \\    "1": {"int": -201},
//         \\    "2": {"float": 0.32},
//         \\    "20": {"bool": false},
//         \\    "3": {"bool": true},
//         \\    "100": {"string": "hello"},
//         \\    "1000": {"symbol": "world"}
//         \\  }
//         \\}
//     ;

//     var scanner = std.json.Scanner.initCompleteInput(std.testing.allocator, input);
//     defer scanner.deinit();
//     const result = try std.json.parseFromTokenSource(NodeInitStateJson, std.testing.allocator, &scanner, .{});
//     defer result.deinit();

//     var expected = NodeInitStateJson{
//         .id = 1031201,
//         .type = "+",
//         .inputs = .{},
//     };
//     defer expected.inputs.deinit(std.testing.allocator);

//     try std.testing.expectEqual(expected.id, result.value.id);
//     try std.testing.expectEqualStrings(expected.type, result.value.type);
//     try std.testing.expectEqualDeep(result.value.inputs.map.get(0).?, InputInitState{ .node = .{ .id = 0, .out_pin = 1 } });
//     try std.testing.expectEqualDeep(result.value.inputs.map.get(1).?, InputInitState{ .int = -201 });
//     try std.testing.expectEqualDeep(result.value.inputs.map.get(2).?, InputInitState{ .float = 0.32 });
//     try std.testing.expectEqualDeep(result.value.inputs.map.get(20).?, InputInitState{ .bool = false });
//     try std.testing.expectEqualDeep(result.value.inputs.map.get(3).?, InputInitState{ .bool = true });
//     try std.testing.expectEqualDeep(result.value.inputs.map.get(100).?, InputInitState{ .string = "hello" });
//     try std.testing.expectEqualDeep(result.value.inputs.map.get(1000).?, InputInitState{ .symbol = "world" });
// }
