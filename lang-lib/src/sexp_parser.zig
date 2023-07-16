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
    };

    /// takes an allocator to base an arena allocator off of
    pub fn parse(alloc: std.mem.Allocator, src: []const u8) Result {
        const State = enum {
            symbol,
            integer,
            float, float_fraction_start,
            bool, char, bool_or_char,
            string, string_escaped_quote,
            between,
            line_comment, multiline_comment,
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
                self.alloc.deinit();
            }

            fn onNextCharAfterTok(self: *@This()) ?Error {
                const c = self.p_src[self.loc.index];
                switch (c) {
                    '1'...'9' => { self.tok_start = self.loc.index; self.state = .integer; },
                    '(' => {
                        var top = self.stack.addOne(self.alloc) catch return .OutOfMemory;
                        top.* = Sexp{.list = std.ArrayList(Sexp).init(self.alloc)};
                    },
                    ')' => {
                        const old_top = self.stack.pop() orelse unreachable;
                        const new_top = peek(&self.stack) orelse unreachable;
                        (new_top.list.addOne()
                            catch return .OutOfMemory
                        ).* = old_top;
                    },
                    ' ', '\t', '\n' => self.state = .between,
                    '"' => { self.tok_start = self.loc.index; self.state = .string; },
                    '#' => { self.tok_start = self.loc.index; self.state = .bool_or_char; },
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
        var expr_arena = std.heap.ArenaAllocator.init(alloc);
        algo_state.alloc = expr_arena.allocator();
        (algo_state.stack.addOne(algo_state.alloc)
             catch return Result.err(.OutOfMemory)
        ).* = Sexp{.list = std.ArrayList(Sexp).init(algo_state.alloc)};
        // FIXME: does errdefer even work here? perhaps I a helper function handle defer... or a mutable arg
        //errdefer algo_state.deinit();
        errdefer algo_state.alloc.deinit();
        errdefer algo_state.stack.deinit();

        while (algo_state.loc.index < src.len) : (algo_state.loc.increment(src[algo_state.loc.index])) {
            const c = src[algo_state.loc.index];
            const tok_slice = src[algo_state.tok_start..algo_state.loc.index];

            std.debug.print("loc: {any}, state: {any}\n", .{algo_state.loc, algo_state.state});

            switch (algo_state.state) {
                .between => if (algo_state.onNextCharAfterTok()) |err| return Result.err(err),
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
                        if (algo_state.onNextCharAfterTok()) |err| return Result.err(err);
                    },
                    '\\' => algo_state.state = .string_escaped_quote,
                    else => {},
                },
                .string_escaped_quote => algo_state.state = .string,
                .integer => switch (c) {
                    '0'...'9' => {},
                    '.' => algo_state.state = .float_fraction_start,
                    ' ','\n','\t',')' => {
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
                .float => switch (c) {
                    else => unreachable
                },
                .bool_or_char => switch (c) {
                    't', 'f' => algo_state.state = .bool,
                    '\\' => algo_state.state = .char,
                    else => return Result{.err=.{.unknownToken = algo_state.loc}},
                },
                .bool => switch (c) {
                    ' ', '\n', '\t' => if (algo_state.onNextCharAfterTok()) |err| return Result.err(err), // TODO: use token
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
    (try expected_list.addOne()).* = Sexp{.borrowedString = "hello\nworld"};
    (try expected_list.addOne()).* = Sexp{.list = std.ArrayList(Sexp).init(t.allocator)};
    (try expected_list.items[2].list.addOne()).* = Sexp{.symbol = "+"};
    (try expected_list.items[2].list.addOne()).* = Sexp{.int = 3};
    (try expected_list.items[2].list.addOne()).* = Sexp{.list = std.ArrayList(Sexp).init(t.allocator)};
    (try expected_list.items[2].list.items[2].list.addOne()).* = Sexp{.symbol = "-"};
    (try expected_list.items[2].list.items[2].list.addOne()).* = Sexp{.int = 2};
    (try expected_list.items[2].list.items[2].list.addOne()).* = Sexp{.int = 5};

    var expected = Parser.Result{.ok = expected_list};
    defer expected.deinit();

    // TODO: deinit result AND every item in it...
    var actual = Parser.parse(t.allocator,
        \\2
        \\"hello
        \\world"
        \\(+ 3(- 2 5))
    );
    defer actual.deinit();

    std.debug.print("\n{any}\n", .{actual});
    std.debug.print("=========================\n", .{});
    for (actual.ok.items) |expr| {
        _ = try expr.write(std.io.getStdErr().writer());
        std.debug.print("\n", .{});
    }
    std.debug.print("=========================\n", .{});

    try t.expectEqual(expected, actual);
}
