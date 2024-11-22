//! intrinsic functions linked into compiler output for usage by the
//! compiler's generated code

// NOTE: the wasm ABI passes all non-singleton (containing one primitive)
// structs by a pointer. So we must use pointers for most structs in this file
// since we're generating WASM code to call these functions by that ABI

pub const GrapplChar = u32;
pub const GrapplBool = u8;

const alloc = @import("std").heap.wasm_allocator;

/// utf8 string (eventually)
pub const GrapplString = extern struct {
    len: u32,
    ptr: [*]u8,
};

pub export fn __grappl_alloc(len: usize) ?*anyopaque {
    return (alloc.allocWithOptions(u8, len, @sizeOf(usize), null) catch return null).ptr;
}

pub export fn __grappl_free(ptr: ?*anyopaque, len: usize) void {
    if (ptr == null) return;
    const multi_ptr: [*]u8 = @as([*]u8, @ptrCast(ptr));
    return alloc.free(multi_ptr[0..len]);
}

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

pub export fn __grappl_string_len(str: *const GrapplString) u32 {
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
