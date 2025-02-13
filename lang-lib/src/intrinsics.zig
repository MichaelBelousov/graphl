//! intrinsic functions linked into compiler output for usage by the
//! compiler's generated code

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

fn __grappl_alloc(len: u32) callconv(.C) ?*anyopaque {
    return (alloc.allocWithOptions(u8, len, @sizeOf(u32), null) catch return null).ptr;
}

fn __grappl_free(ptr: ?*anyopaque, len: u32) callconv(.C) void {
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

    pub fn asSlice(self: *const @This()) []u8 {
        comptime std.debug.assert(builtin.cpu.arch.isWasm());
        return @as([*]u8, @ptrFromInt(self.ptr))[0..self.len];
    }
};

/// -1 if doesn't exist
fn __grappl_string_indexof(str: *const GrapplString, chr: GrapplChar) callconv(.C) i32 {
    const ptr: [*]u8 = @ptrFromInt(str.ptr);
    for (ptr[0..str.len], 0..) |c, i| {
        // TODO: utf8
        if (c == chr) {
            return @intCast(i);
        }
    }
    return -1;
}

fn __grappl_string_len(str: *const GrapplString) callconv(.C) u32 {
    return str.len;
}

fn __grappl_string_join(a: *const GrapplString, b: *const GrapplString) callconv(.C) *GrapplString {
    const data = alloc.alloc(u8, a.len + b.len) catch unreachable;
    @memcpy(data[0..a.len], a);
    @memcpy(data[a.len .. a.len + b.len], b);
    const str = alloc.create(GrapplString) catch unreachable;
    str.* = GrapplString{
        .len = data.len,
        .ptr = @intFromPtr(data.ptr),
    };
    return str;
}

fn __grappl_string_equal(a: *const GrapplString, b: *const GrapplString) callconv(.C) GrapplBool {
    if (a.len != b.len)
        return 0;

    const a_ptr: [*]u8 = @ptrFromInt(a.ptr);
    const b_ptr: [*]u8 = @ptrFromInt(b.ptr);
    for (a_ptr[0..a.len], b_ptr[0..b.len]) |p_a, p_b| {
        if (p_a != p_b)
            return 0;
    }

    return 1;
}

// FIXME: definitely this should be implemented in the language
// via generics, it doesn't make much sense to do this with
// fixed types
fn __grappl_max(a: i32, b: i32) callconv(.C) i32 {
    return @max(a, b);
}
fn __grappl_min(a: i32, b: i32) callconv(.C) i32 {
    return @min(a, b);
}

pub const GrapplVec3 = extern struct {
    x: f64 = 0.0,
    y: f64 = 0.0,
    z: f64 = 0.0,
};

// TODO: force inline this in the compiler
fn __grappl_vec3_x(v: *const GrapplVec3) callconv(.C) f64 {
    return v.x;
}
fn __grappl_vec3_y(v: *const GrapplVec3) callconv(.C) f64 {
    return v.y;
}
fn __grappl_vec3_z(v: *const GrapplVec3) callconv(.C) f64 {
    return v.z;
}

// FIXME: use the stack instead of heap allocating for this
fn __grappl_make_vec3(x: f64, y: f64, z: f64) callconv(.C) *GrapplVec3 {
    const result = alloc.create(GrapplVec3) catch unreachable;
    result.* = GrapplVec3{ .x = x, .y = y, .z = z };
    return result;
}

pub const GrapplRgba = u32;

// TODO: force inline this in the compiler
fn __grappl_rgba_r(v: GrapplRgba) callconv(.C) u8 {
    return @intCast((v >> 24) & 0xff);
}
fn __grappl_rgba_g(v: GrapplRgba) callconv(.C) u8 {
    return @intCast((v >> 16) & 0xff);
}
fn __grappl_rgba_b(v: GrapplRgba) callconv(.C) u8 {
    return @intCast((v >> 8) & 0xff);
}
fn __grappl_rgba_a(v: GrapplRgba) callconv(.C) u8 {
    return @intCast((v >> 0) & 0xff);
}
fn __grappl_make_rgba(r: i32, g: i32, b: i32, a: i32) callconv(.C) GrapplRgba {
    return @intCast(((r & 0xff) << 24) | ((g & 0xff) << 16) | ((b & 0xff) << 8) | ((a & 0xff) << 0));
}

comptime {
    if (builtin.cpu.arch.isWasm()) {
        // NOTE: I wish I could do a loop over @This() and export every function that starts with
        // __grappl_, but if I make them `pub` then they are analyzed somehow by the 64-bit targeting
        // compiler
        // so instead I manually do:
        // grep -Po 'fn __grappl_(\w)+' src/intrinsics.zig | sort -u
        @export(__grappl_alloc, .{ .name = "__grappl_alloc", .linkage = .strong });
        @export(__grappl_free, .{ .name = "__grappl_free", .linkage = .strong });
        @export(__grappl_make_rgba, .{ .name = "__grappl_make_rgba", .linkage = .strong });
        @export(__grappl_make_vec3, .{ .name = "__grappl_make_vec3", .linkage = .strong });
        @export(__grappl_max, .{ .name = "__grappl_max", .linkage = .strong });
        @export(__grappl_min, .{ .name = "__grappl_min", .linkage = .strong });
        @export(__grappl_rgba_a, .{ .name = "__grappl_rgba_a", .linkage = .strong });
        @export(__grappl_rgba_b, .{ .name = "__grappl_rgba_b", .linkage = .strong });
        @export(__grappl_rgba_g, .{ .name = "__grappl_rgba_g", .linkage = .strong });
        @export(__grappl_rgba_r, .{ .name = "__grappl_rgba_r", .linkage = .strong });
        @export(__grappl_string_equal, .{ .name = "__grappl_string_equal", .linkage = .strong });
        @export(__grappl_string_indexof, .{ .name = "__grappl_string_indexof", .linkage = .strong });
        @export(__grappl_string_join, .{ .name = "__grappl_string_join", .linkage = .strong });
        @export(__grappl_string_len, .{ .name = "__grappl_string_len", .linkage = .strong });
        @export(__grappl_vec3_x, .{ .name = "__grappl_vec3_x", .linkage = .strong });
        @export(__grappl_vec3_y, .{ .name = "__grappl_vec3_y", .linkage = .strong });
        @export(__grappl_vec3_z, .{ .name = "__grappl_vec3_z", .linkage = .strong });
    }
}
