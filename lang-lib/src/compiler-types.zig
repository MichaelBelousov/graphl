const BasicMutNodeDesc = @import("./nodes/builtin.zig").BasicMutNodeDesc;

pub const UserFunc = struct {
    id: usize,
    node: BasicMutNodeDesc,
};
