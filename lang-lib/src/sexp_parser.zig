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
                .badInteger => |tok| _ = try writer.print("Fatal: parser thought this token was an integer: '{s}'", .{tok}),
                .badFloat => |tok| _ = try writer.print("Fatal: parser thought this token was a float: '{s}'", .{tok}),
                .unterminatedString => _ = try writer.write("Fatal: unterminated string"),
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

    const ParseTokenResult = struct {
        sexp: Sexp,
        src_span: []const u8,
    };

    inline fn parseStringToken(alloc: std.mem.Allocator, src: []const u8, diag: *Diagnostic) Error!ParseTokenResult {
        std.debug.assert(src.len > 0 and src[0] == '"');
        for (src, 0..) |c, i| {
            // FIXME: escapes
            switch (c) {
                else => {},
                '"' => {
                    return .{
                        .src_span = src[0 .. i + 1],
                        .sexp = Sexp{ .value = .{ .ownedString = try escapeStr(alloc, src[1..i]) } },
                    };
                },
            }
        }

        diag.*.result = .{ .unterminatedString = src[0..] };
        return Error.UnterminatedString;
    }

    const ParseStringResult = struct {
        sexp: Sexp,
        src_span: []const u8,
    };

    // TODO: support hex literals
    inline fn parseNumberOrUnaryNegationToken(src: []const u8, loc: Loc, diag: *Diagnostic) Error!ParseTokenResult {
        std.debug.assert(src.len > 0 and (src[0] == '-' or std.ascii.isDigit(src[0])));

        var right_after: usize = 0;

        const State = enum(u8) {
            sign = 0,
            significand = 1,
            fraction = 2,
            exponent_sign = 3,
            exponent = 4,
        };

        var state: State = if (src[0] == '-') .sign else .significand;

        // FIXME: zig 0.14.0 use labeled switch
        // FIXME: disallow things like:
        // - '000'
        // - '0.'
        // - '512otherToken'
        for (src[1..], 1..) |c, i| {
            switch (state) {
                .sign => switch (c) {
                    '0'...'9' => state = .significand,
                    // FIXME: can the tokenizer do better than this?
                    ' ', '\n', '\t', ')' => break, // this will return immediately below
                    else => {
                        diag.*.result = .{ .unknownToken = loc };
                        return Error.UnknownToken;
                    },
                },
                .significand => switch (c) {
                    '.' => state = .fraction,
                    'e', 'E' => state = .exponent_sign,
                    ' ', '\n', '\t', ')' => {
                        right_after = i;
                        break;
                    },
                    '0'...'9' => {},
                    else => {
                        diag.*.result = .{ .unknownToken = loc };
                        return Error.UnknownToken;
                    },
                },
                .fraction => switch (c) {
                    'e', 'E' => state = .exponent_sign,
                    ' ', '\n', '\t', ')' => {
                        right_after = i;
                        break;
                    },
                    '0'...'9' => {},
                    else => {
                        diag.*.result = .{ .unknownToken = loc };
                        return Error.UnknownToken;
                    },
                },
                .exponent_sign => switch (c) {
                    '+', '-', '0'...'9' => state = .exponent,
                    else => {
                        diag.*.result = .{ .unknownToken = loc };
                        return Error.UnknownToken;
                    },
                },
                .exponent => switch (c) {
                    '0'...'9' => {},
                    ' ', '\n', '\t', ')' => {
                        right_after = i;
                        break;
                    },
                    else => {
                        diag.*.result = .{ .unknownToken = loc };
                        return Error.UnknownToken;
                    },
                },
            }
        }

        if (state == .sign)
            return .{
                .sexp = syms.@"-",
                .src_span = src[0..1],
            };

        if (right_after == 0)
            right_after = src.len;

        const num_src = src[0..right_after];

        if (@intFromEnum(state) >= @intFromEnum(State.fraction)) {
            const res = std.fmt.parseFloat(f64, num_src) catch {
                diag.*.result = .{ .badFloat = num_src };
                return Error.BadFloat;
            };
            return .{
                .sexp = Sexp{ .value = .{ .float = res } },
                .src_span = num_src,
            };
        } else {
            const res = std.fmt.parseInt(i64, num_src, 10) catch {
                diag.*.result = .{ .badInteger = num_src };
                return Error.BadFloat;
            };
            return .{
                .sexp = Sexp{ .value = .{ .int = res } },
                .src_span = num_src,
            };
        }
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

            // TODO: better support quote, hardquote, unquote, unquote splicing
            // NOTE: in graphlt, ' is a quasiquote
            // hardquote is a classic lisp quote, aka not quasiquote ('')
            // unquote, // NOTE: uses $ not ',' like in classic lisps
            // unquote_splicing, // NOTE: uses ... not ',@' like in classic lisps

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

        while (loc.index < src.len) : (loc.increment(src)) {
            const c = src[loc.index];
            const tok_slice = src[tok_start..loc.index];
            switch (state) {
                .integer => switch (c) {
                    '0'...'9' => {},
                    '.' => state = .float_fraction_start,
                    ' ', '\n', '\t', ')', '(' => {
                        // TODO: document why this is unreachable
                        const top = peek(&stack) orelse unreachable;
                        const last = try top.value.list.addOne();
                        const int = std.fmt.parseInt(i64, tok_slice, 10) catch {
                            out_diag.*.result = .{ .badInteger = tok_slice };
                            return Error.BadInteger;
                        };
                        last.* = Sexp{ .value = .{ .int = int } };
                    },
                    else => {
                        out_diag.*.result = .{ .unknownToken = loc };
                        return Error.UnknownToken;
                    },
                },
                .float_fraction_start => switch (c) {
                    '0'...'9' => state = .float,
                    else => {
                        out_diag.*.result = .{ .expectedFraction = loc };
                        return Error.ExpectedFraction;
                    },
                },
                .float => switch (c) {
                    '0'...'9' => {},
                    ' ', '\n', '\t', ')', '(' => {
                        // TODO: document why this is unreachable
                        const top = peek(&stack) orelse unreachable;
                        const last = try top.value.list.addOne();
                        const value = std.fmt.parseFloat(f64, tok_slice) catch {
                            out_diag.*.result = .{ .badFloat = tok_slice };
                            return Error.BadFloat;
                        };
                        last.* = Sexp{ .value = .{ .float = value } };
                    },
                    else => {
                        out_diag.*.result = .{ .unknownToken = loc };
                        return Error.UnknownToken;
                    },
                },
                .hashed_tok_start => switch (c) {
                    't', 'f' => state = .bool,
                    'v' => state = .void,
                    '|' => state = .multiline_comment,
                    '!' => state = .label,
                    else => {
                        out_diag.*.result = .{ .unknownToken = loc };
                        return Error.UnknownToken;
                    },
                },
                .void => {
                    if (std.mem.startsWith(u8, src[loc.index..], "oid")) {
                        const top = peek(&stack) orelse unreachable;
                        const last = try top.value.list.addOne();
                        last.* = sexp.syms.void;

                        {
                            // TODO: can this be less awkward?
                            // skip "voi", the continue of the loop will skip "d"
                            for (0..3) |_| loc.increment(src);
                            if (loc.index >= src.len)
                                break;
                        }
                    } else {
                        out_diag.*.result = .{ .unknownToken = loc };
                        return Error.UnknownToken;
                    }
                },
                .bool => switch (c) {
                    // FIXME: wtf?
                    ' ', '\n', '\t', '(', ')' => {
                        const top = peek(&stack) orelse unreachable;
                        const last = try top.value.list.addOne();
                        // WTF how does this work
                        const prev = src[loc.index - 1];
                        last.* = if (prev == 't') sexp.syms.true else sexp.syms.false;
                    }, // TODO: use token
                    else => {
                        out_diag.*.result = .{ .unknownToken = loc };
                        return Error.UnknownToken;
                    },
                },
                .multiline_comment => switch (c) {
                    '|' => {
                        if (loc.index + 1 < src.len and src[loc.index + 1] == '#') {
                            state = .between;
                            tok_start = loc.index + 1;
                            // skip the |
                            loc.increment(src);
                        }
                    },
                    else => {},
                },
                .label => switch (c) {
                    // FIXME: remove this awkwardness
                    ' ', '\n', '\t', ')', '(' => {
                        const top = peek(&stack) orelse unreachable;
                        const last = if (top.value.list.items.len > 0)
                            &top.value.list.items[top.value.list.items.len - 1]
                        else
                            top;
                        last.label = tok_slice;
                        tok_start = loc.index;
                    },
                    else => {},
                },
                .line_comments => switch (c) {
                    '\n' => state = .between,
                    else => {},
                },
                .symbol => switch (c) {
                    ' ', '\n', '\t', ')', '(' => {
                        // FIXME: remove this awkwardness
                        const top = peek(&stack) orelse unreachable;
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

                        tok_start = loc.index;
                    },
                    else => {},
                },
                .between => {
                    tok_start = loc.index;
                    switch (c) {
                        '-', '0'...'9' => {
                            const tok = try parseNumberOrUnaryNegationToken(src, loc, out_diag);
                            // unreachable cuz we'd have already failed if we popped the last one
                            const top = peek(&stack) orelse unreachable;
                            const last = try top.value.list.addOne();
                            last.* = tok.sexp;
                            tok_start = loc.index;
                            for (tok.src_span) |_| loc.increment(src);
                        },
                        '(' => {
                            const top = try stack.addOne(alloc);
                            top.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                            state = .between;
                            loc.increment(src);
                        },
                        ')' => {
                            const old_top = stack.pop() orelse unreachable;
                            const new_top = peek(&stack) orelse {
                                old_top.deinit(alloc);
                                out_diag.*.result = .{ .unmatchedCloser = loc };
                                return error.UnmatchedCloser;
                            };
                            try new_top.value.list.append(old_top);
                            state = .between;
                        },
                        ' ', '\t', '\n' => state = .between,
                        '"' => {
                            const str_tok = try parseStringToken(alloc, src, out_diag);
                            // unreachable cuz we'd have already failed if we popped the last one
                            const top = peek(&stack) orelse unreachable;
                            const last = try top.value.list.addOne();
                            last.* = str_tok.sexp;
                            tok_start = loc.index;
                            for (str_tok.src_span) |_| loc.increment(src);
                        },
                        '#' => {
                            state = .hashed_tok_start;
                        },
                        ';' => {
                            state = .line_comments;
                        },
                        '\'' => {
                            const is_hardquote = loc.index + 1 <= src.len and src[loc.index + 1] == '\'';
                            if (is_hardquote)
                                loc.increment(src);
                            const top = try stack.addOne(alloc);
                            // FIXME/HACK: replace with a native quote variant in the enum
                            top.* = Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } };
                            (try top.value.list.addOne()).* = if (is_hardquote) syms.hard_quote else syms.quote;
                            state = .between;
                        },
                        else => {
                            out_diag.*.result = .{ .unknownToken = loc };
                            return Error.UnknownToken;
                        },
                    }
                },
            }
        }

        try stack.append(alloc, Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } });

        const top = peek(&stack) orelse unreachable;

        return Sexp{ .value = .{ .module = top.value.list } };
    }
};

test "parseNumberOrUnaryNegationToken" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Parser.Diagnostic = .{ .source = undefined };
    const loc: Loc = undefined;

    try std.testing.expectEqual(0, (try Parser.parseNumberOrUnaryNegationToken("0 ", loc, &diag)).sexp.value.int);
    try std.testing.expectEqual(1, (try Parser.parseNumberOrUnaryNegationToken("1 ", loc, &diag)).sexp.value.int);
    try std.testing.expectEqual(1, (try Parser.parseNumberOrUnaryNegationToken("1", loc, &diag)).sexp.value.int);
    try std.testing.expectEqual(-3, (try Parser.parseNumberOrUnaryNegationToken("-3", loc, &diag)).sexp.value.int);
    try std.testing.expectEqual(syms.@"-", (try Parser.parseNumberOrUnaryNegationToken("-", loc, &diag)).sexp);
    try std.testing.expectEqual(1000, (try Parser.parseNumberOrUnaryNegationToken("1000)", loc, &diag)).sexp.value.int);
    try std.testing.expectEqual(1.5e+2, (try Parser.parseNumberOrUnaryNegationToken("1.5e+2", loc, &diag)).sexp.value.float);
    try std.testing.expectEqual(-0.5e-2, (try Parser.parseNumberOrUnaryNegationToken("-0.5e-2", loc, &diag)).sexp.value.float);
    try std.testing.expectEqual(1.2340002e5, (try Parser.parseNumberOrUnaryNegationToken("1.2340002e5", loc, &diag)).sexp.value.float);
    // NOTE: in lisps, space is the only token separator, -0/ is not a number but it isn't an unknown token necessarily
    try std.testing.expectError(Parser.Error.UnknownToken, Parser.parseNumberOrUnaryNegationToken("-0/", loc, &diag));
}

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
