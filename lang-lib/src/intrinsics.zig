//! intrinsic functions linked into compiler output for usage by the
//! compiler's generated code

pub const GrapplChar = u32;
pub const GrapplBool = u8;

/// utf8 string (eventually)
pub const GrapplString = extern struct {
    len: u32,
    ptr: [*]u8,
};

/// -1 if doesn't exist
pub export fn __grappl_string_indexof(str: GrapplString, chr: GrapplChar) i32 {
    for (str.ptr[0..str.len], 0..) |c, i| {
        // TODO: utf8
        if (c == chr) {
            return @intCast(i);
        }
    }
    return -1;
}

pub export fn __grappl_string_len(str: GrapplString) u32 {
    return str.len;
}

pub export fn __grappl_string_equal(a: GrapplString, b: GrapplString) GrapplBool {
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
