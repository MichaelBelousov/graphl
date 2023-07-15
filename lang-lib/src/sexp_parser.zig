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
                self.index += 1;
            },
            else => {
                self.index += 1;
                self.col += 1;
            }
        }
    }
};


pub const Parser = struct {
    pub const Error = union (enum) {
        expectedFraction: Loc,
        unknownToken: Loc,
        OutOfMemory: void,
        badInteger: []const u8,

        pub fn _format(self: @This(), alloc: std.mem.Allocator) []const u8 {
            _ = self;
            _ = alloc;
            return "";
        }
    };

    pub const Result = union (enum) {
        ok: std.ArrayList(Sexp),
        err: Error,

        fn err(e: Error) @This() {
            return Result{.err = e};
        }
    };

    /// takes an allocator to base an arena allocator off of
    pub fn parse(alloc: std.mem.Allocator, src: []const u8) Result {
        var expr_arena = std.heap.ArenaAllocator.init(alloc);
        errdefer expr_arena.deinit();
        const expr_alloc = expr_arena.allocator();

        var exprs = std.SegmentedList(Sexp, 64){};
        errdefer exprs.deinit(expr_alloc);

        var stack_arena = std.heap.ArenaAllocator.init(alloc);
        defer stack_arena.deinit();
        const stack_alloc = stack_arena.allocator();

        var stack = std.SegmentedList(Sexp, 16){};
        defer stack.deinit(stack_alloc);

        var tok_start: usize = 0;

        var state: enum {
            symbol, integer,
            float, float_fraction_start,
            bool, char,
            string, between, line_comment, multiline_comment,
        } = .between;

        var loc: Loc = .{};
        while (loc.index < src.len) : (loc.increment(src[loc.index])) {
            const c = src[loc.index];
            const tok_slice = src[tok_start..loc.index];
            std.debug.print("loc: {any}, state: {any}\n", .{loc, state});
            switch (state) {
                .between => switch (c) {
                    '1'...'9' => { tok_start = loc.index; state = .integer; },
                    '(' => {
                        var top = stack.addOne(stack_alloc) catch return Result.err(.OutOfMemory);
                        // FIXME: .call isn't necessary
                        top.* = Sexp{.call = .{
                            .callee = undefined,
                            .args = std.ArrayList(Sexp).init(stack_alloc),
                        }};
                    },
                    ')' => {
                        var should_be_expr = stack.pop();
                        if (should_be_expr) |expr| {
                            const last = exprs.addOne(expr_alloc) catch return Result.err(.OutOfMemory);
                            last.* = expr;
                        } else unreachable;
                    },
                    ' ', '\t', '\n' => {},
                    '"' => { tok_start = loc.index; state = .string; },
                    else => { tok_start = loc.index; state = .symbol; },
                    //else => return Result{.err=.{.unknownToken = loc}},
                },
                .symbol => switch (c) {
                    ' ','\n','\t' => {
                        const last = exprs.addOne(expr_alloc) catch return Result.err(.OutOfMemory);
                        last.* = Sexp{.symbol = tok_slice};
                        tok_start = loc.index;
                        state = .between;
                    },
                    // TODO: should reject or finish on '('/')'?
                    else => {},
                },
                .string => switch (c) {
                    // TODO: handle escapes
                    '"' => {
                        const last = exprs.addOne(expr_alloc) catch return Result.err(.OutOfMemory);
                        last.* = Sexp{.borrowedString = tok_slice};
                        tok_start = loc.index;
                        state = .between;
                    },
                    // TODO: should reject or finish on '('/')'?
                    else => {},
                },
                .integer => switch (c) {
                    '0'...'9' => {},
                    '.' => state = .float_fraction_start,
                    ')' => {},
                    ' ','\n','\t' => {
                        const last = exprs.addOne(expr_alloc) catch return Result.err(.OutOfMemory);
                        const int = std.fmt.parseInt(i64, tok_slice, 10)
                            catch return Result{.err = .{.badInteger = tok_slice}};
                        last.* = Sexp{.int = int};
                        tok_start = loc.index;
                        state = .between;
                    },
                    else => return Result{.err=.{.unknownToken = loc}},
                },
                .float_fraction_start => switch (c) {
                    '0'...'9' => state = .float,
                    else => return Result{.err=.{.expectedFraction = loc}},
                },
                .float => switch (c) {
                    else => unreachable
                },
                .bool => unreachable,
                // FIXME: unimplemented
                else => {},
            }
        }

        // FIXME: is this efficient?
        var exprs_list = std.ArrayList(Sexp).init(expr_alloc);
        // FIXME: does errdefer even work here? perhaps I a helper function handle defer... or a pointer...
        errdefer exprs_list.deinit();
        exprs_list.ensureTotalCapacity(exprs.count())
            catch return Result.err(.OutOfMemory);

        {
            var expr_iter = exprs.constIterator(0);
            while (expr_iter.next()) |expr| {
                var next = exprs_list.addOne() catch unreachable;
                next.* = expr.*;
            }
        }

        return .{.ok = exprs_list};
    }
};

const t = std.testing;

test "parse 1" {
    const result = std.ArrayList(Sexp).init(t.allocator);
    const expected = Parser.Result{.ok = result};
    const actual = Parser.parse(t.allocator,
        \\2
        \\(+ 3 2)
    );
    std.debug.print("\n{any}\n", .{actual});
    try t.expectEqual(expected, actual);
}
