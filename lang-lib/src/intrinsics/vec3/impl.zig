//! intrinsic functions linked into compiler output for usage by the
//! compiler's generated code

const GraphlVec3 = @import("./Vec3.zig").GraphlVec3;

pub fn __graphl_vec3_x(v: *const GraphlVec3) callconv(.C) f64 {
    return v.x;
}
pub fn __grappl_vec3_y(v: *const GraphlVec3) callconv(.C) f64 {
    return v.y;
}
pub fn __grappl_vec3_z(v: *const GraphlVec3) callconv(.C) f64 {
    return v.z;
}

// // FIXME: use the stack instead of heap allocating for this
// pub fn __grappl_make_vec3(x: f64, y: f64, z: f64) callconv(.C) *GrapplVec3 {
//     const result = alloc.create(GrapplVec3) catch unreachable;
//     result.* = GrapplVec3{ .x = x, .y = y, .z = z };
//     return result;
// }

comptime {
    const std = @import("std");
    const builtin = @import("builtin");
    if (builtin.cpu.arch.isWasm()) {
        for (std.meta.declarations(@This())) |_decl| {
            const decl = @field(@This(), _decl.name);
            if (std.mem.startsWith(u8, _decl.name, "__graphl_")) {
                @export(&decl, .{ .name = _decl.name, .linkage = .strong });
            }
        }
    }
}
