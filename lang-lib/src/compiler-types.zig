const BasicMutNodeDesc = @import("./nodes/builtin.zig").BasicMutNodeDesc;

// TODO: support async user funcs
// https://kripken.github.io/blog/wasm/2019/07/16/asyncify.html
pub const UserFunc = struct {
    id: usize,
    node: BasicMutNodeDesc,
    @"async": bool,
};
