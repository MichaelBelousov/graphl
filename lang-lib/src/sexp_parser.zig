const std = @import("std");
const builtin = @import("builtin");
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

fn peek(stack: *std.SegmentedList(Sexp, 32)) ?*Sexp {
    if (stack.len == 0) return null;
    return stack.uncheckedAt(stack.len - 1);
}

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

        fn deinit(self: *@This()) void {
            if (self.* == .ok) {
                const alloc = self.ok.allocator;
                for (self.ok.items) |item| item.deinit(alloc);
                self.ok.deinit();
            }
        }

        /// for testing only for now
        fn recursive_eq(self: @This(), other: @This()) bool {
            if (self == .err or other == .err)
                @panic("comparing errors not supported");

            if (self.ok.items.len != other.ok.items.len)
                return false;

            for (self.ok.items) |item, i| {
                const other_item = other.ok.items[i];
                if (!item.recursive_eq(other_item))
                    return false;
            }

            return true;
        }
    };

    pub fn parse(alloc: std.mem.Allocator, src: []const u8) Result {
        const State = enum {
            symbol,
            integer,
            float, float_fraction_start,
            bool, char, bool_or_char,
            string, string_escaped_quote,
            between,
            line_comments,
            multiline_comment,
        };

        const AlgoState = struct {
            loc: Loc = .{},
            state: State = .between,
            p_src: []const u8,
            tok_start: usize = 0,
            stack: std.SegmentedList(Sexp, 32),
            alloc: std.mem.Allocator,

            pub fn init(_src: []const u8) !@This() {
                return .{
                    .p_src = _src,
                    .stack = std.SegmentedList(Sexp, 32){},
                    .alloc = undefined,
                };
            }

            fn deinit(self: *@This()) void {
                self.stack.deinit();
            }

            fn onNextCharAfterTok(self: *@This()) ?Error {
                const c = self.p_src[self.loc.index];
                switch (c) {
                    '1'...'9' => { self.tok_start = self.loc.index; self.state = .integer; },
                    '(' => {
                        var top = self.stack.addOne(self.alloc) catch return .OutOfMemory;
                        top.* = Sexp{.list = std.ArrayList(Sexp).init(self.alloc)};
                        self.state = .between;
                    },
                    ')' => {
                        const old_top = self.stack.pop() orelse unreachable;
                        const new_top = peek(&self.stack) orelse unreachable;
                        (new_top.list.addOne()
                            catch return .OutOfMemory
                        ).* = old_top;
                        self.state = .between;
                    },
                    ' ', '\t', '\n' => self.state = .between,
                    '"' => { self.tok_start = self.loc.index + 1; self.state = .string; },
                    '#' => { self.tok_start = self.loc.index; self.state = .bool_or_char; },
                    ';' => { self.tok_start = self.loc.index; self.state = .line_comments; },
                    else => { self.tok_start = self.loc.index; self.state = .symbol; },
                }
                return null;
            }

            fn unimplemented(_: @This(), feature: [] const u8) noreturn {
                return std.debug.panic("'{s}' unimplemented!", .{feature});
            }
        };

        var algo_state = AlgoState.init(src) catch return Result.err(.OutOfMemory);

        // FIXME: had to move this out of AlgoState.init due to a zig compiler bug
        algo_state.alloc = alloc;
        (algo_state.stack.addOne(algo_state.alloc)
             catch return Result.err(.OutOfMemory)
        ).* = Sexp{.list = std.ArrayList(Sexp).init(algo_state.alloc)};

        // FIXME: does errdefer even work here? perhaps I a helper function handle defer... or a mutable arg
        errdefer algo_state.deinit();

        while (algo_state.loc.index < src.len) : (algo_state.loc.increment(src[algo_state.loc.index])) {
            const c = src[algo_state.loc.index];
            const tok_slice = src[algo_state.tok_start..algo_state.loc.index];

            if (std.os.getenv("DEBUG") != null and builtin.os.tag != .freestanding) {
                std.debug.print("c: {c}, loc: {any}, state: {any}\n", .{c, algo_state.loc, algo_state.state});
            }

            switch (algo_state.state) {
                .between => if (algo_state.onNextCharAfterTok()) |err| return Result.err(err),
                .line_comments => switch (c) {
                    '\n' => algo_state.state = .between,
                    else => {},
                },
                .symbol => switch (c) {
                    ' ','\n','\t',')','(' => {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = top.list.addOne() catch return Result.err(.OutOfMemory);
                        last.* = Sexp{.symbol = tok_slice};
                        algo_state.tok_start = algo_state.loc.index;
                        if (algo_state.onNextCharAfterTok()) |err| return Result.err(err);
                    },
                    else => {},
                },
                .string => switch (c) {
                    // TODO: handle escapes
                    '"' => {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = top.list.addOne() catch return Result.err(.OutOfMemory);
                        last.* = Sexp{.borrowedString = tok_slice};
                        algo_state.tok_start = algo_state.loc.index;
                        algo_state.loc.increment(src[algo_state.loc.index]); // skip ending quote
                        if (algo_state.onNextCharAfterTok()) |err| return Result.err(err);
                    },
                    '\\' => algo_state.state = .string_escaped_quote,
                    else => {},
                },
                .string_escaped_quote => algo_state.state = .string,
                .integer => switch (c) {
                    '0'...'9' => {},
                    '.' => algo_state.state = .float_fraction_start,
                    ' ','\n','\t',')','(' => {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = top.list.addOne() catch return Result.err(.OutOfMemory);
                        const int = std.fmt.parseInt(i64, tok_slice, 10)
                            catch return Result{.err = .{.badInteger = tok_slice}};
                        last.* = Sexp{.int = int};
                        if (algo_state.onNextCharAfterTok()) |err| return Result.err(err);
                    },
                    else => return Result{.err=.{.unknownToken = algo_state.loc}},
                },
                .float_fraction_start => switch (c) {
                    '0'...'9' => algo_state.state = .float,
                    else => return Result{.err=.{.expectedFraction = algo_state.loc}},
                },
                .float => algo_state.unimplemented("float literals"),
                .bool_or_char => switch (c) {
                    't', 'f' => algo_state.state = .bool,
                    '\\' => algo_state.state = .char,
                    else => return Result{.err=.{.unknownToken = algo_state.loc}},
                },
                .bool => switch (c) {
                    ' ','\n','\t','(',')' => {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = top.list.addOne() catch return Result.err(.OutOfMemory);
                        last.* = if (c == 't') sexp.syms.@"true" else sexp.syms.@"false";
                        if (algo_state.onNextCharAfterTok()) |err| return Result.err(err);
                    }, // TODO: use token
                    else => return Result{.err=.{.unknownToken = algo_state.loc}},
                },
                .char => algo_state.unimplemented("char literals"),
                else => algo_state.unimplemented("unhandled case"),
            }
        }

        const top = peek(&algo_state.stack) orelse unreachable;

        return .{.ok = top.list};
    }
};

const t = std.testing;

test "parse 1" {
    var expected_list = std.ArrayList(Sexp).init(t.allocator);
    (try expected_list.addOne()).* = Sexp{.int = 2};
    (try expected_list.addOne()).* = Sexp{.borrowedString = "hel\\\"lo\nworld"};
    (try expected_list.addOne()).* = Sexp{.list = std.ArrayList(Sexp).init(t.allocator)};
    (try expected_list.items[2].list.addOne()).* = Sexp{.symbol = "+"};
    (try expected_list.items[2].list.addOne()).* = Sexp{.int = 3};
    (try expected_list.items[2].list.addOne()).* = Sexp{.list = std.ArrayList(Sexp).init(t.allocator)};
    (try expected_list.items[2].list.items[2].list.addOne()).* = Sexp{.symbol = "-"};
    (try expected_list.items[2].list.items[2].list.addOne()).* = Sexp{.int = 210};
    (try expected_list.items[2].list.items[2].list.addOne()).* = Sexp{.int = 5};

    var expected = Parser.Result{.ok = expected_list};
    defer expected.deinit();

    var actual = Parser.parse(t.allocator,
        \\2
        \\"hel\"lo
        \\world" ;; comment
        \\(+ 3(- 210 5))
    );
    defer actual.deinit();

    // std.debug.print("\n{any}\n", .{actual});
    // std.debug.print("=========================\n", .{});
    // for (actual.ok.items) |expr| {
    //     _ = try expr.write(std.io.getStdErr().writer());
    //     std.debug.print("\n", .{});
    // }
    // std.debug.print("=========================\n", .{});

    try t.expect(expected == .ok);
    try t.expect(actual == .ok);
    try t.expect(expected.recursive_eq(actual));
}
