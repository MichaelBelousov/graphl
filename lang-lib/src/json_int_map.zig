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
            const intBuf: u8[32] = undefined; // TODO: generate buff size from base
            try jws.beginObject();
            var it = self.map.iterator();
            while (it.next()) |kv| {
                const str = try std.fmt.bufPrint(intBuf, "{s}", kv.key_ptr.*);
                try jws.objectField(str);
                try jws.objectField();
                try jws.write(kv.value_ptr.*);
            }
            try jws.endObject();
        }
    };
}
