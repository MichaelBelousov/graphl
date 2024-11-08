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
    pub const Diagnostic = struct {
        source: []const u8,
        result: Result = .none,

        const Result = union(enum(u16)) {
            none = 0,
            expectedFraction: Loc,
            unmatchedCloser: Loc,
            unknownToken: Loc,
            OutOfMemory: void,
            badInteger: []const u8,
        };

        const Code = error{
            ExpectedFraction,
            UnmatchedCloser,
            UnknownToken,
            OutOfMemory,
            BadInteger,
        };

        pub fn code(self: @This()) Code {
            return switch (self.result) {
                .none => unreachable,
                .expectedFraction => Code.ExpectedFraction,
                .unmatchedCloser => Code.UnmatchedCloser,
                .unknownToken => Code.UnknownToken,
                .OutOfMemory => Code.OutOfMemory,
                .badInteger => Code.BadInteger,
            };
        }

        /// returned slice must be freed by the passed in allocator
        pub fn contextualize(self: @This(), writer: anytype) @TypeOf(writer).Error!void {
            return switch (self.result) {
                .none => _ = try writer.write("NotAnError"),
                .expectedFraction => |loc| {
                    return try writer.print(
                        \\There is a decimal point here so expected a fraction:
                        \\ at {}
                        \\  | {s}
                        \\    {}^
                    , .{ loc, try loc.containing_line(self.source), SpacePrint.init(loc.col - 1) });
                },
                .unmatchedCloser => |loc| {
                    return try writer.print(
                        \\Closing parenthesis with no opener:
                        \\ at {}
                        \\  | {s}
                        \\    {}^
                    , .{ loc, try loc.containing_line(self.source), SpacePrint.init(loc.col - 1) });
                },
                .unknownToken => |v| try writer.print("Fatal: unknownToken at {}", .{v}),
                .OutOfMemory => _ = try writer.write("Fatal: System out of memory"),
                .badInteger => _ = try writer.write("Fatal: parser thought this token was an integer: '{s}'"),
            };
        }

        pub fn format(
            self: @This(),
            comptime fmt_str: []const u8,
            fmt_opts: std.fmt.FormatOptions,
            writer: anytype,
        ) @TypeOf(writer).Error!void {
            _ = fmt_str;
            _ = fmt_opts;
            // TODO: use contextualize
            return self.contextualize(writer);
        }
    };

    pub const Error = Diagnostic.Code;

    pub fn parse(alloc: std.mem.Allocator, src: []const u8, maybe_out_diagnostic: ?*Diagnostic) Error!Sexp {
        var ignored_diagnostic: Diagnostic = undefined;
        const out_diag = if (maybe_out_diagnostic) |d| d else &ignored_diagnostic;
        out_diag.* = Diagnostic{ .source = src };

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

            pub fn init(a: std.mem.Allocator, _src: []const u8) !@This() {
                return .{
                    .p_src = _src,
                    .stack = std.SegmentedList(Sexp, 32){},
                    .alloc = a,
                };
            }

            fn deinit(self: *@This()) void {
                var iter = self.stack.constIterator(0);
                while (iter.next()) |item|
                    item.deinit(self.alloc);
                self.stack.deinit(self.alloc);
            }

            fn onNextCharAfterTok(self: *@This(), algo_diag: *Diagnostic) Error!void {
                const c = self.p_src[self.loc.index];
                switch (c) {
                    '1'...'9' => {
                        self.tok_start = self.loc.index;
                        self.state = .integer;
                    },
                    '(' => {
                        const top = try self.stack.addOne(self.alloc);
                        top.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(self.alloc) } };
                        self.state = .between;
                    },
                    ')' => {
                        const old_top = self.stack.pop() orelse unreachable;
                        const new_top = peek(&self.stack) orelse {
                            old_top.deinit(self.alloc);
                            algo_diag.*.result = .{ .unmatchedCloser = self.loc };
                            return error.UnmatchedCloser;
                        };
                        (try new_top.value.list.addOne()).* = old_top;
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
            }

            fn unimplemented(_: @This(), feature: []const u8) noreturn {
                return std.debug.panic("'{s}' unimplemented!", .{feature});
            }
        };

        // FIXME: confirm there is no compiler bug anymore
        var algo_state = try AlgoState.init(alloc, src);
        errdefer algo_state.deinit();

        // FIXME: had to move this out of AlgoState.init due to a zig compiler bug

        (try algo_state.stack.addOne(algo_state.alloc)).* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(algo_state.alloc) } };

        while (algo_state.loc.index < src.len) : (algo_state.loc.increment(src[algo_state.loc.index])) {
            const c = src[algo_state.loc.index];
            const tok_slice = src[algo_state.tok_start..algo_state.loc.index];

            // FIXME: this causes some weird errors (errno 38 or something) to print in the console
            // var maybe_env = std.process.getEnvMap(alloc);
            // if (maybe_env) |*env| {
            //     defer env.deinit();
            //     if (env.get("DEBUG") != null and builtin.os.tag != .freestanding) {
            //         std.debug.print("c: {c}, loc: {any}, state: {any}\n", .{ c, algo_state.loc, algo_state.state });
            //     }
            // } else |_| {}

            switch (algo_state.state) {
                .between => try algo_state.onNextCharAfterTok(out_diag),
                .line_comments => switch (c) {
                    '\n' => algo_state.state = .between,
                    else => {},
                },
                .symbol => switch (c) {
                    ' ', '\n', '\t', ')', '(' => {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = try top.value.list.addOne();

                        // FIXME: do symbol interning instead!
                        var handled = false;
                        const sym_decls = comptime std.meta.declarations(syms);
                        inline for (sym_decls) |sym_decl| {
                            const sym = @field(syms, sym_decl.name);
                            if (std.mem.eql(u8, tok_slice, sym.value.symbol)) {
                                handled = true;
                                last.* = sym;
                            }
                        }
                        // REPORTME: inline for doesn't work with `else`
                        if (!handled) {
                            last.* = Sexp{ .value = .{ .symbol = tok_slice } };
                        }

                        algo_state.tok_start = algo_state.loc.index;
                        try algo_state.onNextCharAfterTok(out_diag);
                    },
                    else => {},
                },
                .string => switch (c) {
                    // TODO: handle escapes
                    '"' => {
                        // FIXME: document why this is unreachable
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = try top.value.list.addOne();
                        last.* = Sexp{ .value = .{ .borrowedString = tok_slice } };
                        algo_state.tok_start = algo_state.loc.index;
                        algo_state.loc.increment(src[algo_state.loc.index]); // skip ending quote
                        try algo_state.onNextCharAfterTok(out_diag);
                    },
                    '\\' => algo_state.state = .string_escaped_quote,
                    else => {},
                },
                .string_escaped_quote => algo_state.state = .string,
                .integer => switch (c) {
                    '0'...'9' => {},
                    '.' => algo_state.state = .float_fraction_start,
                    ' ', '\n', '\t', ')', '(' => {
                        // TODO: document why this is unreachable
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = try top.value.list.addOne();
                        const int = std.fmt.parseInt(i64, tok_slice, 10) catch {
                            out_diag.*.result = .{ .badInteger = tok_slice };
                            return Error.BadInteger;
                        };
                        last.* = Sexp{ .value = .{ .int = int } };
                        try algo_state.onNextCharAfterTok(out_diag);
                    },
                    else => {
                        out_diag.*.result = .{ .unknownToken = algo_state.loc };
                        return Error.UnknownToken;
                    },
                },
                .float_fraction_start => switch (c) {
                    '0'...'9' => algo_state.state = .float,
                    else => {
                        out_diag.*.result = .{ .expectedFraction = algo_state.loc };
                        return Error.ExpectedFraction;
                    },
                },
                .float => algo_state.unimplemented("float literals"),
                .bool_or_char => switch (c) {
                    't', 'f' => algo_state.state = .bool,
                    '\\' => algo_state.state = .char,
                    else => {
                        out_diag.*.result = .{ .unknownToken = algo_state.loc };
                        return Error.UnknownToken;
                    },
                },
                .bool => switch (c) {
                    ' ', '\n', '\t', '(', ')' => {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = try top.value.list.addOne();
                        last.* = if (c == 't') sexp.syms.true else sexp.syms.false;
                        try algo_state.onNextCharAfterTok(out_diag);
                    }, // TODO: use token
                    else => {
                        out_diag.*.result = .{ .unknownToken = algo_state.loc };
                        return Error.UnknownToken;
                    },
                },
                .char => algo_state.unimplemented("char literals"),
                else => algo_state.unimplemented("unhandled case"),
            }
        }

        const top = peek(&algo_state.stack) orelse unreachable;

        return Sexp{ .value = .{ .module = top.value.list } };
    }
};

const t = std.testing;

test "parse 1" {
    var expected = Sexp{ .value = .{ .module = std.ArrayList(Sexp).init(t.allocator) } };
    (try expected.value.module.addOne()).* = Sexp{ .value = .{ .int = 2 } };
    (try expected.value.module.addOne()).* = Sexp{ .value = .{ .borrowedString = "hel\\\"lo\nworld" } };
    (try expected.value.module.addOne()).* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(t.allocator) } };
    (try expected.value.module.items[2].value.list.addOne()).* = Sexp{ .value = .{ .symbol = "+" } };
    (try expected.value.module.items[2].value.list.addOne()).* = Sexp{ .value = .{ .int = 3 } };
    (try expected.value.module.items[2].value.list.addOne()).* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(t.allocator) } };
    (try expected.value.module.items[2].value.list.items[2].value.list.addOne()).* = Sexp{ .value = .{ .symbol = "-" } };
    (try expected.value.module.items[2].value.list.items[2].value.list.addOne()).* = Sexp{ .value = .{ .int = 210 } };
    (try expected.value.module.items[2].value.list.items[2].value.list.addOne()).* = Sexp{ .value = .{ .int = 5 } };
    defer expected.deinit(t.allocator);

    var actual = try Parser.parse(t.allocator,
        \\2
        \\"hel\"lo
        \\world" ;; comment
        \\(+ 3(- 210 5))
    , null);
    defer actual.deinit(t.allocator);

    // std.debug.print("\n{any}\n", .{actual});
    // std.debug.print("=========================\n", .{});
    // for (actual.value.module.items) |expr| {
    //     _ = try expr.write(std.io.getStdErr().writer());
    //     std.debug.print("\n", .{});
    // }
    // std.debug.print("=========================\n", .{});

    try t.expect(expected.recursive_eq(actual));
}

test "parse recovery" {
    const source =
        \\
        \\(+ ('extra 5)))
    ;

    var diagnostic: Parser.Diagnostic = undefined;
    const actual = Parser.parse(t.allocator, source, &diagnostic);
    defer {
        if (actual) |a| a.deinit(t.allocator) else |_| {}
    }
    try t.expectError(error.UnmatchedCloser, actual);

    var buf: [4096]u8 = undefined;
    const err_str = try std.fmt.bufPrint(&buf, "{}", .{diagnostic});

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
    const actual = Parser.parse(t.allocator, source, null);
    defer {
        if (actual) |a| a.deinit(t.allocator) else |_| {}
    }
    try t.expectError(error.UnmatchedCloser, actual);
}
