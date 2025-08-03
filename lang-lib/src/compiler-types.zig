const BasicMutNodeDesc = @import("./nodes/builtin.zig").BasicMutNodeDesc;

// TODO: support async user funcs
// https://kripken.github.io/blog/wasm/2019/07/16/asyncify.html
pub const UserFunc = struct {
    // FIXME: make this optional when creating user funcs from an SDK
    id: usize,
    node: BasicMutNodeDesc,
    @"async": bool = false,
};
