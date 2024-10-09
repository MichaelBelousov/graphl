const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Value = @import("./nodes/builtin.zig").Value;
const Env = @import("./nodes/builtin.zig").Env;

const ExtraIndex = @import("./common.zig").ExtraIndex;
const IndexedNode = @import("./common.zig").GraphTypes.Node;
const IndexedLink = @import("./common.zig").GraphTypes.Link;

const innerParse = json.innerParse;

const JsonIntArrayHashMap = @import("./json_int_map.zig").IntArrayHashMap;

pub const JsonNodeHandle = struct {
    nodeId: i64,
    handleIndex: u32,
};

pub const JsonNodeInput = union(enum) {
    handle: JsonNodeHandle,
    value: Value,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: json.ParseOptions) !@This() {
        return switch (try source.peekNextTokenType()) {
            .object_begin => {
                const object = try innerParse(struct {
                    symbol: ?[]const u8 = null,
                    nodeId: ?i64 = null,
                    handleIndex: ?u32 = null,
                }, allocator, source, options);

                if (object.symbol) |symbol| {
                    if (object.nodeId != null or object.handleIndex != null)
                        return error.UnknownField;
                    return .{ .value = .{ .symbol = symbol } };
                }

                if (object.nodeId != null and object.handleIndex != null) {
                    if (object.symbol != null) return error.UnknownField;
                    return .{ .handle = .{ .nodeId = object.nodeId.?, .handleIndex = object.handleIndex.? } };
                }

                return error.MissingField;
            },
            .string => .{ .value = .{ .string = try innerParse([]const u8, allocator, source, options) } },
            .number => .{ .value = .{ .number = try innerParse(f64, allocator, source, options) } },
            .true, .false => .{ .value = .{ .bool = try innerParse(bool, allocator, source, options) } },
            .null => _: {
                _ = try source.next(); // consume null keyword
                break :_ .{ .value = .null };
            },
            else => error.UnexpectedToken,
        };
    }
};

pub const JsonNode = struct {
    type: []const u8,
    inputs: []const ?JsonNodeInput = &.{},
    outputs: []const ?JsonNodeHandle = &.{},
    // FIXME: create zig type json type that treats optionals not as possibly null but as possibly missing
    data: struct { isEntry: bool = false, comment: ?[]const u8 = null },

    pub fn toEmptyNode(self: @This(), env: Env, index: usize) !IndexedNode {
        var node = env.makeNode(self.type, ExtraIndex{ .index = index }) orelse {
            // if (builtin.mode == .Debug) {
            var iter = env.nodes.iterator();
            std.debug.print("existing nodes:\n", .{});
            while (iter.next()) |node| {
                std.debug.print("{s}\n", .{node.key_ptr.*});
            }
            // }
            return error.UnknownNodeType;
        };
        // NOTE: should probably add ownership to json parsed strings so we can deallocate some...
        node.comment = self.data.comment;
        return node;
    }
};

pub const Import = struct {
    ref: []const u8,
    alias: ?[]const u8,
};

const empty_imports = json.ArrayHashMap([]const Import){};

pub const GraphDoc = struct {
    nodes: JsonIntArrayHashMap(i64, JsonNode, 10),
    imports: json.ArrayHashMap([]const Import) = empty_imports,
};
