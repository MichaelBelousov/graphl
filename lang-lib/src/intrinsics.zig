//! intrinsic functions linked into compiler output for usage by the
//! compiler's generated code

// FIXME: rename everything to graphl

// NOTE: the wasm ABI passes all non-singleton (containing one primitive)
// structs by a pointer. So we must use pointers for most structs in this file
// since we're generating WASM code to call these functions by that ABI

pub const GrapplChar = u32;
pub const GrapplBool = i32;

const std = @import("std");
const builtin = @import("builtin");

const alloc = if (builtin.cpu.arch.isWasm())
    std.heap.wasm_allocator
    // need this to allow local tests
else
    std.testing.failing_allocator;

pub fn __grappl_alloc(len: u32) callconv(.C) ?*anyopaque {
    return (alloc.allocWithOptions(u8, len, @sizeOf(u32), null) catch return null).ptr;
}

pub fn __grappl_free(ptr: ?*anyopaque, len: u32) callconv(.C) void {
    if (ptr == null) return;
    const multi_ptr: [*]u8 = @as([*]u8, @ptrCast(ptr));
    return alloc.free(multi_ptr[0..len]);
}

// FIXME: do string interning
/// utf8 string (eventually)
pub const GrapplString = extern struct {
    len: u32,
    // NOTE: I'd say use opaque to inline the data after the len,
    // but probably better to just do full string interning
    // FIXME: how do I specify a 32-bit integer on a 64-bit platform?
    ptr: u32,

    fn asSlice(self: *const @This()) []u8 {
        comptime std.debug.assert(builtin.cpu.arch.isWasm());
        return @as([*]u8, @ptrFromInt(self.ptr))[0..self.len];
    }
};

/// -1 if doesn't exist
pub fn __grappl_string_indexof(str: *const GrapplString, chr: GrapplChar) callconv(.C) i32 {
    for (str.asSlice(), 0..) |c, i| {
        // TODO: utf8
        if (c == chr) {
            return @intCast(i);
        }
    }
    return -1;
}

pub fn __grappl_string_len(str: *const GrapplString) callconv(.C) u32 {
    return str.len;
}

pub fn __grappl_string_join(a: *const GrapplString, b: *const GrapplString) callconv(.C) *GrapplString {
    const data = alloc.alloc(u8, a.len + b.len) catch unreachable;
    @memcpy(data[0..a.len], a.asSlice());
    @memcpy(data[a.len .. a.len + b.len], b.asSlice());
    const str = alloc.create(GrapplString) catch unreachable;
    str.* = GrapplString{
        .len = data.len,
        .ptr = @intFromPtr(data.ptr),
    };
    return str;
}

pub fn __grappl_string_equal(a: *const GrapplString, b: *const GrapplString) callconv(.C) GrapplBool {
    if (a.len != b.len)
        return 0;

    for (a.asSlice(), b.asSlice()) |p_a, p_b| {
        if (p_a != p_b)
            return 0;
    }

    return 1;
}

// FIXME: definitely this should be implemented in the language
// via generics, it doesn't make much sense to do this with
// fixed types
pub fn __grappl_max(a: i32, b: i32) callconv(.C) i32 {
    return @max(a, b);
}
pub fn __grappl_min(a: i32, b: i32) callconv(.C) i32 {
    return @min(a, b);
}

pub const GrapplVec3 = extern struct {
    x: f64 = 0.0,
    y: f64 = 0.0,
    z: f64 = 0.0,
};

// TODO: force inline this in the compiler
pub fn __grappl_vec3_x(v: *const GrapplVec3) callconv(.C) f64 {
    return v.x;
}
pub fn __grappl_vec3_y(v: *const GrapplVec3) callconv(.C) f64 {
    return v.y;
}
pub fn __grappl_vec3_z(v: *const GrapplVec3) callconv(.C) f64 {
    return v.z;
}

// FIXME: use the stack instead of heap allocating for this
pub fn __grappl_make_vec3(x: f64, y: f64, z: f64) callconv(.C) *GrapplVec3 {
    const result = alloc.create(GrapplVec3) catch unreachable;
    result.* = GrapplVec3{ .x = x, .y = y, .z = z };
    return result;
}

pub const GrapplRgba = u32;

// TODO: force inline this in the compiler
pub fn __grappl_rgba_r(v: GrapplRgba) callconv(.C) u8 {
    return @intCast((v >> 24) & 0xff);
}
pub fn __grappl_rgba_g(v: GrapplRgba) callconv(.C) u8 {
    return @intCast((v >> 16) & 0xff);
}
pub fn __grappl_rgba_b(v: GrapplRgba) callconv(.C) u8 {
    return @intCast((v >> 8) & 0xff);
}
pub fn __grappl_rgba_a(v: GrapplRgba) callconv(.C) u8 {
    return @intCast((v >> 0) & 0xff);
}
pub fn __grappl_make_rgba(r: i32, g: i32, b: i32, a: i32) callconv(.C) GrapplRgba {
    return @intCast(((r & 0xff) << 24) | ((g & 0xff) << 16) | ((b & 0xff) << 8) | ((a & 0xff) << 0));
}

comptime {
    if (builtin.cpu.arch.isWasm()) {
        for (std.meta.declarations(@This())) |_decl| {
            const decl = @field(@This(), _decl.name);
            if (std.mem.startsWith(u8, _decl.name, "__grappl_")) {
                @export(&decl, .{ .name = _decl.name, .linkage = .strong });
            }
        }
    }
}
