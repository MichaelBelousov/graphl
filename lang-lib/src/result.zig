const std = @import("std");
const builtin = @import("builtin");

// TODO: use this for a compressed logging library
fn fmtStringId(
    comptime fmt_str: []const u8
    // FIXME: also need to take the args into account, which can be done by generating a custom type
    // comptime fmt_args_type: type
) usize {
    return @intFromPtr(fmt_str.ptr);
}

fn ResultDecls(comptime R: type, comptime Self: type) type {
    return struct {
        pub fn is_ok(self: Self) bool {
            return self.err == null;
        }

        pub fn is_err(self: Self) bool {
            return !self.is_ok();
        }

        pub fn ok(r: R) Self {
            return Self{
                .value = r,
                .err = null,
                .errCode = 0,
            };
        }

        pub fn err(e: [*:0]const u8) Self {
            return Self{
                .value = undefined,
                .err = e,
                // FIXME: not used
                .errCode = 1,
            };
        }

        pub fn err_as(self: @This(), comptime T: type) Result(T) {
            std.debug.assert(self.is_err());
            return Result(T) {
                .value = undefined,
                .err = self.err,
                .errCode = self.errCode,
            };
        }


        pub fn fmt_err(alloc: std.mem.Allocator, comptime fmt_str: []const u8, fmt_args: anytype) Self {
            return Self{
                .value = undefined,
                .err = std.fmt.allocPrintZ(alloc, "Error: " ++ fmt_str, fmt_args) catch |sub_err| std.debug.panic("error '{}' while explaining an error", .{sub_err}),
                .errCode = fmtStringId(fmt_str),
            };
        }

        pub fn c_fmt_err(comptime fmt_str: []const u8, fmt_args: anytype) Self {
            return if (builtin.link_libc)
                Result(@TypeOf(R.value)).fmt_err(std.heap.raw_c_allocator, fmt_str, fmt_args)
            else @compileError("Must compile with libc");
        }
    };
}

pub fn Result(comptime R: type) type {
    // FIXME: gross
    if (@typeInfo(R) == .Struct and @typeInfo(R).Struct.layout == .Extern or @typeInfo(R) == .Union and @typeInfo(R).Union.layout == .Extern) {
        return extern struct {
            /// not initialized if err is not 0/null
            value: R = undefined,
            err: ?[*:0]const u8 = null,
            // TODO: try to compress to u16 if possible
            /// 0 if value is valid
            errCode: usize = 0,

            const Self = @This();
            // FIXME: doesn't seem to work on 0.10.1
            //pub usingnamespace ResultDecls(R, @This());

            pub fn is_ok(self: Self) bool {
                return self.err == null;
            }

            pub fn is_err(self: Self) bool {
                return !self.is_ok();
            }

            pub fn ok(r: R) Self {
                return Self{ .value = r };
            }

            pub fn err_as(self: @This(), comptime T: type) Result(T) {
                std.debug.assert(self.is_err());
                return Result(T) {
                    .err = self.err,
                    .errCode = self.errCode,
                };
            }

            pub fn err(e: [*:0]const u8) Self {
                return Self{
                    .err = e,
                    // FIXME: not used
                    .errCode = 1,
                };
            }

            pub fn fmt_err(alloc: std.mem.Allocator, comptime fmt_str: []const u8, fmt_args: anytype) Self {
                return Self{
                    .value = undefined,
                    .err = std.fmt.allocPrintZ(alloc, "Error: " ++ fmt_str, fmt_args) catch |sub_err| std.debug.panic("error '{}' while explaining an error", .{sub_err}),
                    .errCode = fmtStringId(fmt_str),
                };
            }

            pub fn c_fmt_err(comptime fmt_str: []const u8, fmt_args: anytype) Self {
                return if (builtin.link_libc)
                    Result(@TypeOf(R.value)).fmt_err(std.heap.raw_c_allocator, fmt_str, fmt_args)
                else @compileError("Must compile with libc");
            }
        };
    } else {
        return struct {
            /// not initialized if err is not 0/null
            value: R,
            err: ?[*:0]const u8,
            // TODO: try to compress to u16 if possible
            /// 0 if value is valid
            errCode: usize,

            const Self = @This();
            // FIXME:
            //pub usingnamespace ResultDecls(R, @This());

            pub fn is_ok(self: Self) bool {
                return self.err == null;
            }

            pub fn is_err(self: Self) bool {
                return !self.is_ok();
            }

            pub fn ok(r: R) Self {
                return Self{
                    .value = r,
                    .err = null,
                    .errCode = 0,
                };
            }

            /// FIXME: this is designed to be free'd from C libraries, and the current implementation
            /// doesn't support that for string literals
            /// you can't pass a string literal to it
            pub fn err(e: [*:0]const u8) Self {
                return Self{
                    .value = undefined,
                    .err = e,
                    .errCode = 1, // TODO: determine from e
                };
            }

            pub fn err_as(self: @This(), comptime T: type) Result(T) {
                std.debug.assert(self.is_err());
                return Result(T) {
                    .value = undefined,
                    .err = self.err,
                    .errCode = self.errCode,
                };
            }

            pub fn fmt_err(alloc: std.mem.Allocator, comptime fmt_str: []const u8, fmt_args: anytype) Self {
                return Self{
                    .value = undefined,
                    .err = std.fmt.allocPrintZ(alloc, "Error: " ++ fmt_str, fmt_args) catch |sub_err| std.debug.panic("error '{}' while explaining an error", .{sub_err}),
                    .errCode = fmtStringId(fmt_str),
                };
            }

            pub fn c_fmt_err(comptime fmt_str: []const u8, fmt_args: anytype) Self {
                return if (builtin.link_libc)
                    Result(@TypeOf(R.value)).fmt_err(std.heap.raw_c_allocator, fmt_str, fmt_args)
                else @compileError("Must compile with libc");
            }
        };
    }
}

test "result" {
    const T = extern struct { i: i64 };
    try std.testing.expectEqual(Result(T).ok(T{ .i = 100 }), Result(T){
        .value = T{ .i = 100 },
        .errCode = 0,
        .err = null,
    });
}
