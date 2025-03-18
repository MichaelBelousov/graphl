const std = @import("std");
const builtin = @import("builtin");
const sexp = @import("./sexp.zig");
const Sexp = sexp.Sexp;
const syms = sexp.syms;
const Loc = @import("./loc.zig").Loc;
// const InternPool = @import("./InternPool.zig").InternPool;
var pool = &@import("./InternPool.zig").pool;

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
            unmatchedOpener: Loc,
            unknownToken: Loc,
            OutOfMemory: void,
            badInteger: []const u8,
            badFloat: []const u8,
            unterminatedString: []const u8,
            emptyQuote: Loc,
        };

        const Code = error{
            ExpectedFraction,
            UnmatchedCloser,
            UnmatchedOpener,
            UnknownToken,
            OutOfMemory,
            BadInteger,
            BadFloat,
            UnterminatedString,
            EmptyQuote,
        };

        pub fn code(self: @This()) Code {
            return switch (self.result) {
                .none => unreachable,
                .expectedFraction => Code.ExpectedFraction,
                .unmatchedCloser => Code.UnmatchedCloser,
                .unmatchedOpener => Code.UnmatchedOpener,
                .unknownToken => Code.UnknownToken,
                .OutOfMemory => Code.OutOfMemory,
                .badInteger => Code.BadInteger,
                .badFloat => Code.BadFloat,
                .unterminatedString => Code.UnterminatedString,
                .emptyQuote => Code.EmptyQuote,
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
                .unmatchedOpener => |loc| {
                    return try writer.print(
                        \\Opening parenthesis with no closer:
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
                .emptyQuote => |loc| {
                    return try writer.print(
                        \\Quote without any immediately following expression:
                        \\ at {}
                        \\  | {s}
                        \\    {}^
                    , .{ loc, try loc.containing_line(self.source), SpacePrint.init(loc.col - 1) });
                },
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
        var state: enum { normal, escaped } = .normal;
        for (src[1..], 1..) |c, i| {
            switch (state) {
                .normal => switch (c) {
                    else => {},
                    '\\' => {
                        state = .escaped;
                    },
                    '"' => {
                        return .{
                            .src_span = src[0 .. i + 1],
                            .sexp = Sexp{ .value = .{ .ownedString = try escapeStr(alloc, src[1..i]) } },
                        };
                    },
                },
                .escaped => state = .normal,
            }
        }

        diag.*.result = .{ .unterminatedString = src[0..] };
        return Error.UnterminatedString;
    }

    inline fn parseSymbolToken(src: []const u8, loc: Loc, diag: *Diagnostic) Error!ParseTokenResult {
        std.debug.assert(src.len > 0);
        const end = std.mem.indexOfAny(u8, src, &.{ ' ', '\n', '\t', ')' }) orelse src.len;
        const in_src_sym = src[0..end];
        if (in_src_sym.len == 0) {
            diag.result = .{ .emptyQuote = loc };
            return Error.EmptyQuote;
        }

        const sym = pool.getSymbol(in_src_sym);
        return ParseTokenResult{
            .sexp = Sexp{ .value = .{ .symbol = sym } },
            .src_span = sym,
        };
    }

    // TODO: support hex literals
    inline fn parseNumberOrUnaryNegationToken(src: []const u8, loc: Loc, diag: *Diagnostic) Error!ParseTokenResult {
        std.debug.assert(src.len > 0 and (src[0] == '-' or std.ascii.isDigit(src[0])));

        var right_after: usize = src.len;

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

    inline fn parseLabelToken(src: []const u8, loc: Loc, diag: *Diagnostic) Error![]const u8 {
        std.debug.assert(src.len >= 2);
        const end = std.mem.indexOfAnyPos(u8, src, 2, &.{ ' ', '\n', '\t', ')' }) orelse src.len;

        const label = src[0..end];

        const empty_label = label.len <= 2;
        if (empty_label) {
            // TODO: add an "expected" field to "unknownToken"?
            diag.result = .{ .unknownToken = loc };
            return Error.UnknownToken;
        } else {
            return label;
        }
    }

    inline fn parseMultiLineComment(src: []const u8, loc: Loc, diag: *Diagnostic) Error![]const u8 {
        std.debug.assert(src.len >= 2);
        const end = std.mem.indexOfPos(u8, src, 2, "|#") orelse {
            diag.result = .{ .unknownToken = loc };
            return Error.UnterminatedString;
        };
        _ = end;
    }

    inline fn parseLineComment(whole_src: []const u8, loc: Loc) []const u8 {
        const rest = whole_src[loc.index..];
        std.debug.assert(rest.len >= 1);
        const end = std.mem.indexOfScalarPos(u8, rest, 1, '\n') orelse rest.len;
        // NOTE: we do not include the new line
        return rest[0..end];
    }

    const ParseHashStartedTokenResult = union(enum) {
        sexp: ParseTokenResult,
        label: []const u8,
        //comment: []const u8,
    };

    // TODO: rename token "parse" functions to token "scan" functions
    inline fn parseHashStartedToken(src: []const u8, loc: Loc, diag: *Diagnostic) Error!ParseHashStartedTokenResult {
        std.debug.assert(src.len >= 1);

        for (src[1..]) |c| {
            switch (c) {
                't' => {
                    if (src.len > 2) switch (src[2]) {
                        ' ', '\n', '\t', ')' => {},
                        else => break,
                    };
                    return .{ .sexp = .{
                        .sexp = syms.true,
                        .src_span = src[0..2],
                    } };
                },
                'f' => {
                    if (src.len > 2) switch (src[2]) {
                        ' ', '\n', '\t', ')' => {},
                        else => break,
                    };
                    return .{ .sexp = .{
                        .sexp = syms.false,
                        .src_span = src[0..2],
                    } };
                },
                'v' => {
                    if (!std.mem.eql(u8, src[2..5], "oid"))
                        break;
                    if (src.len > 5) switch (src[5]) {
                        ' ', '\n', '\t', ')' => {},
                        else => break,
                    };
                    return .{ .sexp = .{
                        .sexp = syms.void,
                        .src_span = src[0..5],
                    } };
                },
                '!' => {
                    return .{ .label = try parseLabelToken(src, loc, diag) };
                },
                // '|' => {
                //     return parseMultiLineComment(src, loc, diag);
                // },
                else => break,
            }
        }

        diag.*.result = .{ .unknownToken = loc };
        return Error.UnknownToken;
    }

    // FIXME: force arena allocator
    pub fn parse(
        alloc: std.mem.Allocator,
        src: []const u8,
        maybe_out_diagnostic: ?*Diagnostic,
    ) Error!Sexp {
        var ignored_diagnostic: Diagnostic = undefined;
        const out_diag = if (maybe_out_diagnostic) |d| d else &ignored_diagnostic;
        out_diag.* = Diagnostic{ .source = src };

        var loc: Loc = .{};
        // TODO: store the the opener position and whether it's a quote
        var stack: std.SegmentedList(Sexp, 32) = .{};
        defer stack.deinit(alloc);
        errdefer {
            var iter = stack.constIterator(0);
            while (iter.next()) |item|
                item.deinit(alloc);
        }

        try stack.append(alloc, Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } });

        while (loc.index < src.len) : (loc.increment(src)) {
            const c = src[loc.index];

            // std.debug.print("src=", .{});
            // std.json.encodeJsonString(src[loc.index..], .{}, std.io.getStdErr().writer()) catch unreachable;
            // std.debug.print("\n", .{});

            switch (c) {
                '-', '0'...'9' => {
                    const tok = try parseNumberOrUnaryNegationToken(src[loc.index..], loc, out_diag);
                    // unreachable cuz we'd have already failed if we popped the last one
                    const top = peek(&stack) orelse unreachable;
                    const last = try top.value.list.addOne();
                    last.* = tok.sexp;
                    for (0..tok.src_span.len - 1) |_| loc.increment(src);
                },
                '(' => {
                    try stack.append(alloc, Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(alloc) } });
                },
                ')' => {
                    const old_top = stack.pop() orelse unreachable;
                    const new_top = peek(&stack) orelse {
                        old_top.deinit(alloc);
                        out_diag.*.result = .{ .unmatchedCloser = loc };
                        return error.UnmatchedCloser;
                    };
                    try new_top.value.list.append(old_top);
                },
                '"' => {
                    const tok = try parseStringToken(alloc, src[loc.index..], out_diag);
                    // unreachable cuz we'd have already failed if we popped the last one
                    const top = peek(&stack) orelse unreachable;
                    const last = try top.value.list.addOne();
                    last.* = tok.sexp;
                    for (0..tok.src_span.len - 1) |_| loc.increment(src);
                },
                '#' => {
                    // TODO: consider making all these token scanners
                    const hash_tok = try parseHashStartedToken(src[loc.index..], loc, out_diag);
                    switch (hash_tok) {
                        .sexp => |tok| {
                            // unreachable cuz we'd have already failed if we popped the last one
                            const top = peek(&stack) orelse unreachable;
                            const last = try top.value.list.addOne();
                            last.* = tok.sexp;
                            for (0..tok.src_span.len - 1) |_| loc.increment(src);
                        },
                        .label => |label| {
                            const top = peek(&stack) orelse unreachable;
                            const last = if (top.value.list.items.len > 0)
                                &top.value.list.items[top.value.list.items.len - 1]
                            else
                                top;
                            last.label = label;
                            for (0..label.len - 1) |_| loc.increment(src);
                        },
                    }
                },
                ';' => {
                    const comment = parseLineComment(src, loc);
                    // note we increment the newline which wasn't included
                    for (comment) |_| loc.increment(src);
                },
                // FIXME: temporarily this just returns a symbol
                '\'' => {
                    const tok = try parseSymbolToken(src[loc.index..], loc, out_diag);
                    // unreachable cuz we'd have already failed if we popped the last one
                    const top = peek(&stack) orelse unreachable;
                    const last = try top.value.list.addOne();
                    last.* = tok.sexp;
                    for (0..tok.src_span.len - 1) |_| loc.increment(src);
                },
                // ascii table
                '!',
                //"#
                '$'...'&',
                // '()
                '*'...',',
                //-
                '.'...'/',
                //0...9
                ':',
                //;
                '<'...'@',
                'A'...'Z',
                '['...'`',
                'a'...'z',
                '{'...'~',
                => {
                    const tok = try parseSymbolToken(src[loc.index..], loc, out_diag);
                    // unreachable cuz we'd have already failed if we popped the last one
                    const top = peek(&stack) orelse unreachable;
                    const last = try top.value.list.addOne();
                    last.* = tok.sexp;
                    for (0..tok.src_span.len - 1) |_| loc.increment(src);
                },
                ' ', '\n', '\t' => {},
                else => {
                    out_diag.*.result = .{ .unknownToken = loc };
                    return Error.UnknownToken;
                },
            }
        }

        if (stack.count() != 1) {
            // TODO: track the opener position for each level in the stack
            out_diag.result = .{ .unmatchedOpener = loc };
            return Error.UnmatchedOpener;
        }

        const top = peek(&stack) orelse unreachable;

        // TODO: move
        const result = Sexp{ .value = .{ .module = top.value.list } };
        errdefer result.deinit();

        stack.uncheckedAt(0).* = Sexp{ .value = .void };

        return result;
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

test "parse all" {
    var expected = Sexp{ .value = .{ .module = std.ArrayList(Sexp).init(t.allocator) } };
    (try expected.value.module.addOne()).* = Sexp{ .value = .{ .int = 0 }, .label = "#!label1" };
    (try expected.value.module.addOne()).* = Sexp{ .value = .{ .int = 2 } };
    (try expected.value.module.addOne()).* = Sexp{ .value = .{ .ownedString = "hel\"lo\nworld" }, .label = "#!label2" };
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
    (try expected.value.module.addOne()).* = Sexp{ .value = .{ .symbol = "'sym" } };
    (try expected.value.module.addOne()).* = Sexp{ .value = .{ .ownedString = "" } };
    defer {
        // don't free fake ownedString
        expected.value.module.items[2] = Sexp{ .value = .void };
        expected.value.module.items[8] = Sexp{ .value = .void };
        expected.deinit(t.allocator);
    }

    const source =
        \\0
        \\#!label1
        \\2
        \\"hel\"lo
        \\world" #!label2 ;; comment
        \\(+ 3 (- 210 5)
        \\) #!label3
        \\#void
        \\#t
        \\#f
        \\'sym
        \\""
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
        if (actual) |a| a.deinit(t.allocator) else |_| {
            std.debug.print("diagnostic:\n{}\n", .{diagnostic});
        }
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
    const source =
        \\
        \\(+ ('extra 5)
    ;

    var diagnostic: Parser.Diagnostic = undefined;
    const actual = Parser.parse(t.allocator, source, &diagnostic);
    defer {
        if (actual) |a| a.deinit(t.allocator) else |_| {}
    }
    try t.expectError(error.UnmatchedOpener, actual);

    // FIXME: the arrow should point to the opener!
    try t.expectFmt(
        \\Opening parenthesis with no closer:
        \\ at unknown:2:14
        \\  | (+ ('extra 5)
        \\                 ^
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
