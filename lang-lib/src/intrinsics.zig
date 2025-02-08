//! intrinsic functions linked into compiler output for usage by the
//! compiler's generated code

// NOTE: the wasm ABI passes all non-singleton (containing one primitive)
// structs by a pointer. So we must use pointers for most structs in this file
// since we're generating WASM code to call these functions by that ABI

pub const GrapplChar = u32;
pub const GrapplBool = u8;

const alloc = if (@import("builtin").cpu.arch.isWasm())
    @import("std").heap.wasm_allocator
    // need this to allow local tests
else
    @import("std").testing.failing_allocator;

pub export fn __grappl_alloc(len: usize) ?*anyopaque {
    return (alloc.allocWithOptions(u8, len, @sizeOf(usize), null) catch return null).ptr;
}

pub export fn __grappl_free(ptr: ?*anyopaque, len: usize) void {
    if (ptr == null) return;
    const multi_ptr: [*]u8 = @as([*]u8, @ptrCast(ptr));
    return alloc.free(multi_ptr[0..len]);
}

// FIXME: do string interning
/// utf8 string (eventually)
pub const GrapplString = extern struct {
    len: usize,
    ptr: [*]u8,
};

/// -1 if doesn't exist
pub export fn __grappl_string_indexof(str: *const GrapplString, chr: GrapplChar) i32 {
    for (str.ptr[0..str.len], 0..) |c, i| {
        // TODO: utf8
        if (c == chr) {
            return @intCast(i);
        }
    }
    return -1;
}

pub export fn __grappl_string_len(str: *const GrapplString) usize {
    return str.len;
}

pub export fn __grappl_string_join(a: *const GrapplString, b: *const GrapplString) *GrapplString {
    const data = alloc.alloc(u8, a.len + b.len) catch unreachable;
    const str = alloc.create(GrapplString) catch unreachable;
    str.* = GrapplString{
        .len = data.len,
        .ptr = data.ptr,
    };
    return str;
}

pub export fn __grappl_string_equal(a: *const GrapplString, b: *const GrapplString) GrapplBool {
    if (a.len != b.len)
        return 0;

    for (a.ptr[0..a.len], b.ptr[0..b.len]) |p_a, p_b| {
        if (p_a != p_b)
            return 0;
    }

    return 1;
}

// FIXME: definitely this should be implemented in the language
// via generics, it doesn't make much sense to do this with
// fixed types
pub export fn __grappl_max(a: i32, b: i32) i32 {
    return @max(a, b);
}
pub export fn __grappl_min(a: i32, b: i32) i32 {
    return @min(a, b);
}

pub const GrapplVec3 = extern struct {
    x: f64 = 0.0,
    y: f64 = 0.0,
    z: f64 = 0.0,
};

// TODO: force inline this in the compiler
pub export fn __grappl_vec3_x(v: *const GrapplVec3) f64 {
    return v.x;
}
pub export fn __grappl_vec3_y(v: *const GrapplVec3) f64 {
    return v.y;
}
pub export fn __grappl_vec3_z(v: *const GrapplVec3) f64 {
    return v.z;
}
pub export fn __grappl_make_vec3(x: f64, y: f64, z: f64) GrapplVec3 {
    return GrapplVec3{ .x = x, .y = y, .z = z };
}

pub const GrapplRgba = u32;

// TODO: force inline this in the compiler
pub export fn __grappl_rgba_r(v: GrapplRgba) u8 {
    return @intCast((v >> 24) & 0xff);
}
pub export fn __grappl_rgba_g(v: GrapplRgba) u8 {
    return @intCast((v >> 16) & 0xff);
}
pub export fn __grappl_rgba_b(v: GrapplRgba) u8 {
    return @intCast((v >> 8) & 0xff);
}
pub export fn __grappl_rgba_a(v: GrapplRgba) u8 {
    return @intCast((v >> 0) & 0xff);
}
pub export fn __grappl_make_rgba(r: i32, g: i32, b: i32, a: i32) GrapplRgba {
    return @intCast(((r & 0xff) << 24) | ((g & 0xff) << 16) | ((b & 0xff) << 8) | ((a & 0xff) << 0));
}
