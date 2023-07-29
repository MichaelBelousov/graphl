const std = @import("std");

// TODO: use this for a compressed logging library
fn fmtStringId(comptime fmt_str: []const u8) usize {
    return @intFromPtr(fmt_str.ptr);
    //return @intFromPtr(fmt_str.ptr);
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
                .result = r,
                .err = null,
                .errCode = 0,
            };
        }

        pub fn err(e: [*:0]const u8) Self {
            return Self{
                .result = undefined,
                .err = e,
                // FIXME: not used
                .errCode = 1,
            };
        }

        pub fn fmt_err(alloc: std.mem.Allocator, comptime fmt_str: []const u8, fmt_args: anytype) Self {
            return Self{
                .result = undefined,
                .err = std.fmt.allocPrintZ(alloc, "Error: " ++ fmt_str, fmt_args) catch |sub_err| std.debug.panic("error '{}' while explaining an error", .{sub_err}),
                .errCode = fmtStringId(fmt_str),
            };
        }
    };
}

pub fn Result(comptime R: type) type {
    // FIXME: gross
    if (@typeInfo(R) == .Struct and @typeInfo(R).Struct.layout == .Extern or @typeInfo(R) == .Union and @typeInfo(R).Union.layout == .Extern) {
        return extern struct {
            /// not initialized if err is not 0/null
            result: R,
            err: ?[*:0]const u8,
            // TODO: try to compress to u16 if possible
            /// 0 if result is valid
            errCode: usize,

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
                return Self{
                    .result = r,
                    .err = null,
                    .errCode = 0,
                };
            }

            pub fn err(e: [*:0]const u8) Self {
                return Self{
                    .result = undefined,
                    .err = e,
                    // FIXME: not used
                    .errCode = 1,
                };
            }

            pub fn fmt_err(alloc: std.mem.Allocator, comptime fmt_str: []const u8, fmt_args: anytype) Self {
                return Self{
                    .result = undefined,
                    .err = std.fmt.allocPrintZ(alloc, "Error: " ++ fmt_str, fmt_args) catch |sub_err| std.debug.panic("error '{}' while explaining an error", .{sub_err}),
                    .errCode = fmtStringId(fmt_str),
                };
            }
        };
    } else {
        return struct {
            /// not initialized if err is not 0/null
            result: R,
            err: ?[*:0]const u8,
            // TODO: try to compress to u16 if possible
            /// 0 if result is valid
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
                    .result = r,
                    .err = null,
                    .errCode = 0,
                };
            }

            pub fn err(e: [*:0]const u8) Self {
                return Self{
                    .result = undefined,
                    .err = e,
                    // FIXME: not used
                    .errCode = 1,
                };
            }

            pub fn fmt_err(alloc: std.mem.Allocator, comptime fmt_str: []const u8, fmt_args: anytype) Self {
                return Self{
                    .result = undefined,
                    .err = std.fmt.allocPrintZ(alloc, "Error: " ++ fmt_str, fmt_args) catch |sub_err| std.debug.panic("error '{}' while explaining an error", .{sub_err}),
                    .errCode = fmtStringId(fmt_str),
                };
            }
        };
    }
}

test "result" {
    const T = extern struct { i: i64 };
    try std.testing.expectEqual(Result(T).ok(T{ .i = 100 }), Result(T){
        .result = T{ .i = 100 },
        .errCode = 0,
        .err = null,
    });
}
