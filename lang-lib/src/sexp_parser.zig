const std = @import("std");
const builtin = @import("builtin");
const sexp = @import("./sexp.zig");
const Sexp = sexp.Sexp;
const syms = sexp.syms;
const Loc = @import("./loc.zig").Loc;

fn peek(stack: *std.SegmentedList(Sexp, 32)) ?*Sexp {
    if (stack.len == 0) return null;
    return stack.uncheckedAt(stack.len - 1);
}

pub const SpacePrint = struct {
    spaces: usize = 0,

    pub fn init(spaces: usize) @This() {
        return @This(){ .spaces = spaces };
    }

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        var i: usize = self.spaces;
        while (i != 0) : (i -= 1) {
            _ = try writer.write(" ");
        }
    }
};

pub const Parser = struct {
    pub const Error = union(enum) {
        expectedFraction: Loc,
        unmatchedCloser: Loc,
        unknownToken: Loc,
        OutOfMemory: void,
        badInteger: []const u8,

        /// returned slice must be freed by the passed in allocator
        pub fn contextualize(self: @This(), alloc: std.mem.Allocator, source: []const u8) ![]const u8 {
            return switch (self) {
                .expectedFraction => |loc| {
                    return try std.fmt.allocPrint(alloc,
                        \\There is a decimal point here so expected a fraction:
                        \\ at {}
                        \\  | {s}
                        \\    {}^
                    , .{ loc, try loc.containing_line(source), SpacePrint.init(loc.col - 1) });
                },
                .unmatchedCloser => |loc| {
                    return try std.fmt.allocPrint(alloc,
                        \\Closing parenthesis with no opener:
                        \\ at {}
                        \\  | {s}
                        \\    {}^
                    , .{ loc, try loc.containing_line(source), SpacePrint.init(loc.col - 1) });
                },
                .unknownToken => "Fatal: unknownToken: '{s}'",
                .OutOfMemory => "Fatal: System out of memory",
                .badInteger => "Fatal: parser thought this token was an integer: '{s}'",
            };
        }
    };

    pub const Result = union(enum) {
        ok: std.ArrayList(Sexp),
        err: Error,

        fn err(e: Error) @This() {
            return Result{ .err = e };
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

            for (self.ok.items, 0..) |item, i| {
                const other_item = other.ok.items[i];
                if (!item.recursive_eq(other_item))
                    return false;
            }

            return true;
        }
    };

    pub fn parse(alloc: std.mem.Allocator, src: []const u8) Result {
        // NOTE: tagged union errdefer hack
        var result: Result = undefined;

        const State = enum {
            symbol,
            integer,
            float,
            float_fraction_start,
            bool,
            char,
            bool_or_char,
            string,
            string_escaped_quote,
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
                var iter = self.stack.constIterator(0);
                while (iter.next()) |item|
                    item.deinit(self.alloc);
                self.stack.deinit(self.alloc);
            }

            fn onNextCharAfterTok(self: *@This()) ?Error {
                const c = self.p_src[self.loc.index];
                switch (c) {
                    '1'...'9' => {
                        self.tok_start = self.loc.index;
                        self.state = .integer;
                    },
                    '(' => {
                        var top = self.stack.addOne(self.alloc) catch return .OutOfMemory;
                        top.* = Sexp{ .list = std.ArrayList(Sexp).init(self.alloc) };
                        self.state = .between;
                    },
                    ')' => {
                        const old_top = self.stack.pop() orelse unreachable;
                        const new_top = peek(&self.stack) orelse {
                            old_top.deinit(self.alloc);
                            return Error{ .unmatchedCloser = self.loc };
                        };
                        (new_top.list.addOne() catch return .OutOfMemory).* = old_top;
                        self.state = .between;
                    },
                    ' ', '\t', '\n' => self.state = .between,
                    '"' => {
                        self.tok_start = self.loc.index + 1;
                        self.state = .string;
                    },
                    '#' => {
                        self.tok_start = self.loc.index;
                        self.state = .bool_or_char;
                    },
                    ';' => {
                        self.tok_start = self.loc.index;
                        self.state = .line_comments;
                    },
                    else => {
                        self.tok_start = self.loc.index;
                        self.state = .symbol;
                    },
                }
                return null;
            }

            fn unimplemented(_: @This(), feature: []const u8) noreturn {
                return std.debug.panic("'{s}' unimplemented!", .{feature});
            }
        };

        var algo_state = AlgoState.init(src) catch return Result.err(.OutOfMemory);

        // FIXME: had to move this out of AlgoState.init due to a zig compiler bug
        algo_state.alloc = alloc;
        (algo_state.stack.addOne(algo_state.alloc) catch return Result.err(.OutOfMemory)).* = Sexp{ .list = std.ArrayList(Sexp).init(algo_state.alloc) };

        defer if (result == .err) algo_state.deinit();

        while (algo_state.loc.index < src.len) : (algo_state.loc.increment(src[algo_state.loc.index])) {
            const c = src[algo_state.loc.index];
            const tok_slice = src[algo_state.tok_start..algo_state.loc.index];

            if (std.os.getenv("DEBUG") != null and builtin.os.tag != .freestanding) {
                std.debug.print("c: {c}, loc: {any}, state: {any}\n", .{ c, algo_state.loc, algo_state.state });
            }

            switch (algo_state.state) {
                .between => if (algo_state.onNextCharAfterTok()) |err| {
                    result = Result.err(err);
                    return result;
                },
                .line_comments => switch (c) {
                    '\n' => algo_state.state = .between,
                    else => {},
                },
                .symbol => switch (c) {
                    ' ', '\n', '\t', ')', '(' => {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = top.list.addOne() catch return Result.err(.OutOfMemory);
                        last.* = Sexp{ .symbol = tok_slice };
                        algo_state.tok_start = algo_state.loc.index;
                        if (algo_state.onNextCharAfterTok()) |err| {
                            result = Result.err(err);
                            return result;
                        }
                    },
                    else => {},
                },
                .string => switch (c) {
                    // TODO: handle escapes
                    '"' => {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = top.list.addOne() catch return Result.err(.OutOfMemory);
                        last.* = Sexp{ .borrowedString = tok_slice };
                        algo_state.tok_start = algo_state.loc.index;
                        algo_state.loc.increment(src[algo_state.loc.index]); // skip ending quote
                        if (algo_state.onNextCharAfterTok()) |err| {
                            result = Result.err(err);
                            return result;
                        }
                    },
                    '\\' => algo_state.state = .string_escaped_quote,
                    else => {},
                },
                .string_escaped_quote => algo_state.state = .string,
                .integer => switch (c) {
                    '0'...'9' => {},
                    '.' => algo_state.state = .float_fraction_start,
                    ' ', '\n', '\t', ')', '(' => {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = top.list.addOne() catch return Result.err(.OutOfMemory);
                        const int = std.fmt.parseInt(i64, tok_slice, 10) catch return Result{ .err = .{ .badInteger = tok_slice } };
                        last.* = Sexp{ .int = int };
                        if (algo_state.onNextCharAfterTok()) |err| {
                            result = Result.err(err);
                            return result;
                        }
                    },
                    else => return Result{ .err = .{ .unknownToken = algo_state.loc } },
                },
                .float_fraction_start => switch (c) {
                    '0'...'9' => algo_state.state = .float,
                    else => return Result{ .err = .{ .expectedFraction = algo_state.loc } },
                },
                .float => algo_state.unimplemented("float literals"),
                .bool_or_char => switch (c) {
                    't', 'f' => algo_state.state = .bool,
                    '\\' => algo_state.state = .char,
                    else => return Result{ .err = .{ .unknownToken = algo_state.loc } },
                },
                .bool => switch (c) {
                    ' ', '\n', '\t', '(', ')' => {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = top.list.addOne() catch return Result.err(.OutOfMemory);
                        last.* = if (c == 't') sexp.syms.true else sexp.syms.false;
                        if (algo_state.onNextCharAfterTok()) |err| {
                            result = Result.err(err);
                            return result;
                        }
                    }, // TODO: use token
                    else => return Result{ .err = .{ .unknownToken = algo_state.loc } },
                },
                .char => algo_state.unimplemented("char literals"),
                else => algo_state.unimplemented("unhandled case"),
            }
        }

        const top = peek(&algo_state.stack) orelse unreachable;

        return .{ .ok = top.list };
    }
};

const t = std.testing;

test "parse 1" {
    var expected_list = std.ArrayList(Sexp).init(t.allocator);
    (try expected_list.addOne()).* = Sexp{ .int = 2 };
    (try expected_list.addOne()).* = Sexp{ .borrowedString = "hel\\\"lo\nworld" };
    (try expected_list.addOne()).* = Sexp{ .list = std.ArrayList(Sexp).init(t.allocator) };
    (try expected_list.items[2].list.addOne()).* = Sexp{ .symbol = "+" };
    (try expected_list.items[2].list.addOne()).* = Sexp{ .int = 3 };
    (try expected_list.items[2].list.addOne()).* = Sexp{ .list = std.ArrayList(Sexp).init(t.allocator) };
    (try expected_list.items[2].list.items[2].list.addOne()).* = Sexp{ .symbol = "-" };
    (try expected_list.items[2].list.items[2].list.addOne()).* = Sexp{ .int = 210 };
    (try expected_list.items[2].list.items[2].list.addOne()).* = Sexp{ .int = 5 };

    var expected = Parser.Result{ .ok = expected_list };
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

test "parse recovery" {
    const source =
        \\
        \\(+ ('extra 5)))
    ;

    var actual = Parser.parse(t.allocator, source);
    defer actual.deinit();

    try t.expect(actual == .err);

    const err_str = try actual.err.contextualize(t.allocator, source);
    defer t.allocator.free(err_str);

    try t.expectEqualStrings(
        \\Closing parenthesis with no opener:
        \\ at unknown:2:15
        \\  | (+ ('extra 5)))
        \\                  ^
    , err_str);
}

test "simple error1" {
    const source =
        \\())
    ;
    var actual = Parser.parse(t.allocator, source);
    defer actual.deinit();
    try t.expect(actual == .err);
}
