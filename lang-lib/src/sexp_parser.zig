const std = @import("std");
const sexp = @import("./sexp.zig");
const Sexp = sexp.Sexp;
const syms = sexp.syms;

pub const Loc = extern struct {
    /// 1-indexed
    line: usize = 1,
    /// 1-indexed
    col: usize = 1,
    index: usize = 0,

    fn increment(self: *@This(), c: u8) void {
        switch (c) {
            '\n' => {
                self.line += 1;
                self.col = 1;
            },
            else => {
                self.index += 1;
                self.col += 1;
            }
        }
    }
};


pub const Parser = struct {
    pub const Result = union (enum) {
        ok: Sexp,
        err: union (enum) {
            expectedFraction: Loc,
            expectedDecimal: void,

            pub fn format(self: @This(), alloc: std.mem.Allocator) []const u8 {}
        },
    };

    pub fn parse(alloc: std.mem.Allocator, src: []const u8) Result {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const stack = std.SegmentedList(Sexp, 16){};

        var tok_start = 0;

        const state: enum {
            symbol, integer,
            float, float_fraction_start,
            bool, char,
            string, between, line_comment, multiline_comment,
        } = .between;

        var loc: Loc = .{};
        while (loc.index < src.len) : (loc.increment(src[loc.index])) {
            const c = src[loc.index];
            const tok_slice = src[tok_start..loc.index];
            switch (state) {
                .between => {

                },
                .symbol => {

                },
                .string => {

                },
                .integer => switch (c) {
                    '.' => state = .float_fraction_start,
                    else => return Result{.err={}},
                },
                .float_fraction_start => switch (c) {
                    '0'...'9' => state = .float,
                    else => return Result{.err=.{.unexpectedFrac = loc}},
                },
                .float => switch (c) {

                },
            }
        }
    }
};

