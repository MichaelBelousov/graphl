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
            badFloat: []const u8,
            unterminatedString: []const u8,
        };

        const Code = error{
            ExpectedFraction,
            UnmatchedCloser,
            UnknownToken,
            OutOfMemory,
            BadInteger,
            BadFloat,
            UnterminatedString,
        };

        pub fn code(self: @This()) Code {
            return switch (self.result) {
                .none => unreachable,
                .expectedFraction => Code.ExpectedFraction,
                .unmatchedCloser => Code.UnmatchedCloser,
                .unknownToken => Code.UnknownToken,
                .OutOfMemory => Code.OutOfMemory,
                .badInteger => Code.BadInteger,
                .badFloat => Code.BadFloat,
                .unterminatedString => Code.UnterminatedString,
            };
        }

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
                .unknownToken => |loc| {
                    return try writer.print(
                        \\Unknown token:
                        \\ at {}
                        \\  | {s}
                        \\    {}^
                    , .{ loc, try loc.containing_line(self.source), SpacePrint.init(loc.col - 1) });
                },
                .OutOfMemory => _ = try writer.write("Fatal: System out of memory"),
                .badInteger => _ = try writer.write("Fatal: parser thought this token was an integer: '{s}'"),
                .badFloat => _ = try writer.write("Fatal: parser thought this token was a float: '{s}'"),
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

    inline fn parseStringToken(alloc: std.mem.Allocator, src: []const u8, diag: *Diagnostic) Error!Sexp {
        _ = alloc;
        std.debug.assert(src.len > 0 and src[0] == '"');
        for (src, 0..) |c, i| {
            // FIXME: escapes
            switch (c) {
                else => {},
                '"' => {
                    return Sexp{ .value = .{ .borrowedString = src[0..i + 1] } };
                },
            }
        }

        diag.*.result = .{ .unterminatedString = src[0..] };
        return Error.UnexpectedEof;
    }

    inline fn parseNumberToken(src: []const u8, diag: *Diagnostic) Error!Sexp {
        std.debug.assert(src.len > 0 and (src[0] == '-' or std.ascii.isDigit(src[0])));
        var has_dot = false;
        var end = 0;

        // NOTE: naive and allows '000' and also '0.'
        for (src, 0..) |c, i| {
            switch (c) {
                '-', '0'...'9', 'e', 'E' => { },
                '.' => has_dot = true,
                else => { end = i; },
            }
        }

        const num_src = src[0..end];

        // TODO: support hex
        if (has_dot) {
            const res = std.fmt.parseFloat(f64, num_src) catch {
                diag.*.result = .{ .badFloat = num_src };
                return Error.BadFloat;
            };
            return Sexp{.value = .{ .float = res } };
        } else {
            const res = std.fmt.parseInt(i64, num_src) catch {
                diag.*.result = .{ .badInteger = num_src };
                return Error.BadFloat;
            };
            return Sexp{.value = .{ .int = res } };
        }
    }

    test parseNumberToken {
        const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const diag: Diagnostic = .{};

        std.testing.expectEqual((try parseNumberToken("0x10Ff)", diag)).value.int, 0x10ff);
        std.testing.expectEqual((try parseNumberToken("1.5e2+", diag)).value.int, 0x10ff);
        std.testing.expectEqual((try parseNumberToken("-0.5e+2-", diag)).value.int, 0x10ff);
        std.testing.expectEqual((try parseNumberToken("-0/", diag)).value.float, -0.0);
        std.testing.expectEqual((try parseNumberToken("-3", diag)).value.int, 0x10ff);
    }


    // FIXME: force arena allocator
    pub fn parse(alloc: std.mem.Allocator, src: []const u8, maybe_out_diagnostic: ?*Diagnostic) Error!Sexp {
        var ignored_diagnostic: Diagnostic = undefined;
        const out_diag = if (maybe_out_diagnostic) |d| d else &ignored_diagnostic;
        out_diag.* = Diagnostic{ .source = src };

        const State = enum {
            between,

            symbol,
            integer,
            float,
            float_fraction_start,

            hashed_tok_start,
            label,
            void,
            bool,

            // NOTE: in graphlt, ' is a quasiquote
            quote,
            // // hardquote is a classic lisp quote, aka not quasiquote ('')
            hardquote, // in graphlt it is ''
            // unquote, // NOTE: uses $ not ',' like in classic lisps
            // unquote_splicing, // NOTE: uses ... not ',@' like in classic lisps

            string,
            line_comments,
            multiline_comment,
        };

        var loc: Loc = .{};
        var state: State = .between;
        var tok_start: usize = 0;
        var stack: std.SegmentedList(Sexp, 32) = .{};
        defer {
            var iter = stack.constIterator(0);
            while (iter.next()) |item|
                item.deinit(alloc);
            stack.deinit(alloc);
        }

        const c = src[loc.index];

        switch (c) {
            '0'...'9' => {
                tok_start = loc.index;
                state = .integer;
                parseNumberToken(src, out_diag);
            },
            '(' => {
                const top = try stack.addOne(alloc);
                top.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                state = .between;
                loc.increment(c);
            },
            ')' => {
                const old_top = stack.pop() orelse unreachable;
                const new_top = peek(&stack) orelse {
                    old_top.deinit(alloc);
                    out_diag.*.result = .{ .unmatchedCloser = loc };
                    return error.UnmatchedCloser;
                };
                (try new_top.value.list.addOne()).* = old_top;
                state = .between;
            },
            ' ', '\t', '\n' => state = .between,
            '"' => {
                tok_start = loc.index + 1;
                state = .string;
            },
            '#' => {
                tok_start = loc.index;
                state = .hashed_tok_start;
            },
            ';' => {
                tok_start = loc.index;
                state = .line_comments;
            },
            '\'' => {
                const top = try stack.addOne(alloc);
                // FIXME/HACK: replace with a native quote variant in the enum
                top.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                (try top.value.list.addOne()).* = syms.quote;
                state = .between;
            },
            else => {
                tok_start = loc.index;
                state = .symbol;
            },
        }

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
                        // FIXME: remove this awkwardness
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = try top.value.list.addOne();

                        // FIXME: do symbol interning and a prefix tree instead!
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
                        last.* = Sexp{ .value = .{ .ownedString = try escapeStr(alloc, tok_slice) } };
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
                .float => switch (c) {
                    '0'...'9' => {},
                    ' ', '\n', '\t', ')', '(' => {
                        // TODO: document why this is unreachable
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = try top.value.list.addOne();
                        const value = std.fmt.parseFloat(f64, tok_slice) catch {
                            out_diag.*.result = .{ .badFloat = tok_slice };
                            return Error.BadFloat;
                        };
                        last.* = Sexp{ .value = .{ .float = value } };
                        try algo_state.onNextCharAfterTok(out_diag);
                    },
                    else => {
                        out_diag.*.result = .{ .unknownToken = algo_state.loc };
                        return Error.UnknownToken;
                    },
                },
                .hashed_tok_start => switch (c) {
                    't', 'f' => algo_state.state = .bool,
                    'v' => algo_state.state = .void,
                    '\\' => algo_state.state = .char,
                    '|' => algo_state.state = .multiline_comment,
                    '!' => algo_state.state = .label,
                    else => {
                        out_diag.*.result = .{ .unknownToken = algo_state.loc };
                        return Error.UnknownToken;
                    },
                },
                .void => {
                    if (std.mem.startsWith(u8, src[algo_state.loc.index..], "oid")) {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = try top.value.list.addOne();
                        last.* = sexp.syms.void;

                        {
                            // TODO: can this be less awkward?
                            // skip "voi", the continue of the loop will skip "d"
                            for (0..3) |_| algo_state.loc.increment(src[algo_state.loc.index]);
                            if (algo_state.loc.index >= src.len)
                                break;
                        }

                        try algo_state.onNextCharAfterTok(out_diag);
                    } else {
                        out_diag.*.result = .{ .unknownToken = algo_state.loc };
                        return Error.UnknownToken;
                    }
                },
                .bool => switch (c) {
                    // FIXME: wtf?
                    ' ', '\n', '\t', '(', ')' => {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = try top.value.list.addOne();
                        // WTF how does this work
                        const prev = src[algo_state.loc.index - 1];
                        last.* = if (prev == 't') sexp.syms.true else sexp.syms.false;
                        try algo_state.onNextCharAfterTok(out_diag);
                    }, // TODO: use token
                    else => {
                        out_diag.*.result = .{ .unknownToken = algo_state.loc };
                        return Error.UnknownToken;
                    },
                },
                .char => {
                    const top = peek(&algo_state.stack) orelse unreachable;
                    const last = try top.value.list.addOne();
                    // FIXME: use a dedicated char sexp type?
                    last.* = Sexp{ .value = .{ .borrowedString = src[algo_state.loc.index..algo_state.loc.index] } };
                },
                .multiline_comment => switch (c) {
                    '|' => {
                        if (algo_state.loc.index + 1 < src.len and src[algo_state.loc.index + 1] == '#') {
                            algo_state.state = .between;
                            algo_state.tok_start = algo_state.loc.index + 1;
                            // skip the |
                            algo_state.loc.increment(src[algo_state.loc.index]);
                        }
                    },
                    else => {},
                },
                .label => switch (c) {
                    // FIXME: remove this awkwardness
                    ' ', '\n', '\t', ')', '(' => {
                        const top = peek(&algo_state.stack) orelse unreachable;
                        const last = if (top.value.list.items.len > 0)
                            &top.value.list.items[top.value.list.items.len - 1]
                        else
                            top;
                        last.label = tok_slice;
                        algo_state.tok_start = algo_state.loc.index;
                        try algo_state.onNextCharAfterTok(out_diag);
                    },
                    else => {},
                },
            }
        }

        const top = peek(&algo_state.stack) orelse unreachable;

        return Sexp{ .value = .{ .module = top.value.list } };
    }
};

// FIXME: use a known spec like JSON strings, to handle e.g. \x or \u{}
fn escapeStr(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var buff = try std.ArrayListUnmanaged(u8).initCapacity(alloc, src.len);
    defer buff.deinit(alloc);
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\\') i += 1;
        if (i >= src.len) break;
        buff.appendAssumeCapacity(src[i]);
    }
    return try buff.toOwnedSlice(alloc);
}

const t = std.testing;

test "parse 1" {
    var expected = Sexp{ .value = .{ .module = std.ArrayList(Sexp).init(t.allocator) } };
    (try expected.value.module.addOne()).* = Sexp{ .value = .{ .int = 0 }, .label = "#!label1" };
    (try expected.value.module.addOne()).* = Sexp{ .value = .{ .int = 2 } };
    (try expected.value.module.addOne()).* = Sexp{ .value = .{ .borrowedString = "hel\"lo\nworld" }, .label = "#!label2" };
    (try expected.value.module.addOne()).* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(t.allocator) }, .label = "#!label3" };
    (try expected.value.module.items[3].value.list.addOne()).* = Sexp{ .value = .{ .symbol = "+" } };
    (try expected.value.module.items[3].value.list.addOne()).* = Sexp{ .value = .{ .int = 3 } };
    (try expected.value.module.items[3].value.list.addOne()).* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(t.allocator) } };
    (try expected.value.module.items[3].value.list.items[2].value.list.addOne()).* = Sexp{ .value = .{ .symbol = "-" } };
    (try expected.value.module.items[3].value.list.items[2].value.list.addOne()).* = Sexp{ .value = .{ .int = 210 } };
    (try expected.value.module.items[3].value.list.items[2].value.list.addOne()).* = Sexp{ .value = .{ .int = 5 } };
    (try expected.value.module.addOne()).* = syms.void;
    (try expected.value.module.addOne()).* = syms.true;
    (try expected.value.module.addOne()).* = syms.false;
    defer expected.deinit(t.allocator);

    const source =
        \\0
        \\#!label1
        \\2
        \\"hel\"lo
        \\world" #!label2 ;; comment
        \\(+ 3(- 210 5)
        \\) #!label3
        \\#void
        \\#t
        \\#f
    ;

    var diag = Parser.Diagnostic{ .source = source };
    defer if (diag.result != .none) {
        std.debug.print("diag={}", .{diag});
    };
    var actual = try Parser.parse(t.allocator, source, &diag);
    defer actual.deinit(t.allocator);

    const result = expected.recursive_eq(actual);

    if (!result) {
        std.debug.print("====== ACTUAL ===========\n", .{});
        std.debug.print("{any}\n", .{actual});
        std.debug.print("====== EXPECTED =========\n", .{});
        std.debug.print("{any}\n", .{expected});
        std.debug.print("=========================\n", .{});
    }

    try t.expect(result);
}

test "parse recover unmatched closing paren" {
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

    try t.expectFmt(
        \\Closing parenthesis with no opener:
        \\ at unknown:2:15
        \\  | (+ ('extra 5)))
        \\                  ^
    , "{}", .{diagnostic});
}

test "parse recover unmatched open paren" {
    if (true) return error.SkipZigTest;

    const source =
        \\
        \\(+ ('extra 5)
    ;

    var diagnostic: Parser.Diagnostic = undefined;
    const actual = Parser.parse(t.allocator, source, &diagnostic);
    defer {
        if (actual) |a| a.deinit(t.allocator) else |_| {}
    }
    try t.expectError(error.UnmatchedCloser, actual);

    try t.expectFmt(
        \\Opening parenthesis with no closer:
        \\ at unknown:2:1
        \\  | (+ ('extra 5)
        \\    ^
    , "{}", .{diagnostic});
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
