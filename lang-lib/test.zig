const std = @import("std");

pub const TypeInfo = struct {
    name: []const u8,
    field_names: []const []const u8 = &.{},
    // should structs allow constrained generic fields?
    field_types: []const Type = &.{},
};

pub const Type = *const TypeInfo;

pub const NodeDesc = struct {
    name: []const u8,
    context: *const align(@sizeOf(usize)) anyopaque,
    _getInputs: *const fn(NodeDesc) []const i32,

    pub fn getInputs(self: @This()) []const i32 { return self._getInputs(self); }
};

pub const Node = struct {
    desc: *const NodeDesc,
};

const BasicNodeDesc = struct {
    name: []const u8,
    inputs: []const i32 = &.{},
    outputs: []const i32 = &.{}
};

/// caller owns memory!
pub fn basicNode(in_desc: *const BasicNodeDesc) NodeDesc {
    const NodeImpl = struct {
        const Self = @This();

        pub fn getInputs(node: NodeDesc) []const i32 {
            const desc: @TypeOf(in_desc) = @ptrCast(node.context);
            return desc.inputs;
        }
    };

    return NodeDesc{
        .name = in_desc.name,
        .context = @ptrCast(in_desc),
        ._getInputs = NodeImpl.getInputs,
    };
}

// NOTE: this is the problem, just creating two consts that use this causes the segfault it seems
// FIXME: isn't this going to be illegal? https://github.com/ziglang/zig/issues/7396
// FIXME: move to own file
fn comptimeAllocOrFallback(fallback_allocator: std.mem.Allocator, comptime T: type, comptime count: usize) std.mem.Allocator.Error![]T {
    comptime var comptime_slot: [if (@inComptime()) count else 0]T = undefined;
    return if (@inComptime()) &comptime_slot
         else try fallback_allocator.alloc(T, count);
}

pub const VarNodes = struct {
    get: NodeDesc,
    set: NodeDesc,

    fn init(alloc: std.mem.Allocator, var_name: []const u8, var_type: i32) !VarNodes {
        // FIXME: test and plug non-comptime alloc leaks
        const getterInputs = try comptimeAllocOrFallback(alloc, i32, 1);
        getterInputs[0] = var_type;

        const getter_name =
            if (@inComptime()) std.fmt.comptimePrint("get_{s}", .{var_name})
            else try std.fmt.allocPrint(alloc, "get_{s}", .{var_name});

        const setterInputs = try comptimeAllocOrFallback(alloc, i32, 2);
        setterInputs[0] = 1;
        setterInputs[1] = 2;

        const setter_name =
            if (@inComptime()) std.fmt.comptimePrint("get_{s}", .{var_name})
            else try std.fmt.allocPrint(alloc, "get_{s}", .{var_name});

        return VarNodes{
            .get = basicNode(&.{
                .name = getter_name,
                .inputs = getterInputs,
            }),
            .set = basicNode(&.{
                .name = setter_name,
                .inputs = setterInputs,
            }),
        };
    }
};

pub const temp = struct {
    const nodes = (struct {
        // TODO: replace with live vars
        const capsule_component = VarNodes.init(std.testing.failing_allocator, "capsule_component", 10)
            catch unreachable;
        const current_spawn_point = VarNodes.init(std.testing.failing_allocator, "current_spawn_point", 20)
            catch unreachable;

        get_capsule_component: NodeDesc = capsule_component.get,
        set_capsule_component: NodeDesc = capsule_component.set,

        get_current_spawn_point: NodeDesc = current_spawn_point.get,
        set_current_spawn_point: NodeDesc = current_spawn_point.set,
    }){};
};

test "node types" {
    try std.testing.expectEqual(temp.nodes.get_capsule_component.getInputs()[0], 10);
    try std.testing.expectEqual(temp.nodes.set_capsule_component.getInputs()[0], 1);
    try std.testing.expectEqual(temp.nodes.set_capsule_component.getInputs()[1], 2);

    var comp2 = VarNodes.init(std.testing.allocator, "comp2", 30)
        catch unreachable;

    try std.testing.expectEqual(comp2.get.getInputs()[0], 30);
    try std.testing.expectEqual(comp2.set.getInputs()[0], 1);
    try std.testing.expectEqual(comp2.set.getInputs()[1], 2);

    try std.testing.expectEqual(temp.nodes.get_current_spawn_point.getInputs()[0], 20);
    try std.testing.expectEqual(temp.nodes.set_current_spawn_point.getInputs()[0], 1);
    try std.testing.expectEqual(temp.nodes.set_current_spawn_point.getInputs()[1], 2);
}
