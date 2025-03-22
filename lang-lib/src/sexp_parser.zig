//! parses the graphlt form of s-expressions
//! I should probably rename them to like gexp
//! since they are a full graph with backlinks

const std = @import("std");
const builtin = @import("builtin");
const sexp = @import("./sexp.zig");
const Sexp = sexp.Sexp;
const ModuleContext = sexp.ModuleContext;
const syms = sexp.syms;
const Loc = @import("./loc.zig").Loc;
// const InternPool = @import("./InternPool.zig").InternPool;
const pool = &@import("./InternPool.zig").pool;

fn peek(stack: *std.SegmentedList(u32, 32)) ?u32 {
    if (stack.len == 0) return null;
    return stack.uncheckedAt(stack.len - 1).*;
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

        // fixme, make camel case
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
            duplicateLabel: struct {
                first: Loc,
                second: Loc,
                name: []const u8,
            },
            unknownLabel: struct {
                loc: Loc,
                name: []const u8,
            },
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
            DuplicateLabel,
            UnknownLabel,
        };

        pub fn code(self: @This()) Code {
            // fixme: capitalize
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
                .duplicateLabel => Code.DuplicateLabel,
                .unknownLabel => Code.UnknownLabel,
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
                .duplicateLabel => |info| {
                    return try writer.print(
                        \\Found duplicate label '{s}' at {}
                        \\  | {s}
                        \\    {}^
                        \\note: first found at {}
                        \\  | {s}
                        \\    {}^
                    , .{
                        info.name,
                        info.second,
                        try info.second.containing_line(self.source),
                        SpacePrint.init(info.second.col - 1),
                        info.first,
                        try info.first.containing_line(self.source),
                        SpacePrint.init(info.first.col - 1),
                    });
                },
                .unknownLabel => |info| {
                    return try writer.print(
                        \\Unknown label '{s}' at {}
                        \\  | {s}
                        \\    {}^
                    , .{
                        info.name,
                        info.loc,
                        try info.loc.containing_line(self.source),
                        SpacePrint.init(info.loc.col - 1),
                    });
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
    inline fn parseHashStartedToken(src: []const u8, loc: Loc, diag: *Diagnostic) Error!ParseTokenResult {
        std.debug.assert(src.len >= 1);

        for (src[1..]) |c| {
            switch (c) {
                't' => {
                    if (src.len > 2) switch (src[2]) {
                        ' ', '\n', '\t', ')' => {},
                        else => break,
                    };
                    return .{
                        .sexp = syms.true,
                        .src_span = src[0..2],
                    };
                },
                'f' => {
                    if (src.len > 2) switch (src[2]) {
                        ' ', '\n', '\t', ')' => {},
                        else => break,
                    };
                    return .{
                        .sexp = syms.false,
                        .src_span = src[0..2],
                    };
                },
                'v' => {
                    if (!std.mem.eql(u8, src[2..5], "oid"))
                        break;
                    if (src.len > 5) switch (src[5]) {
                        ' ', '\n', '\t', ')' => {},
                        else => break,
                    };
                    return .{
                        .sexp = syms.void,
                        .src_span = src[0..5],
                    };
                },
                // '!' => {
                //     return .{ .label = try parseLabelToken(src, loc, diag) };
                // },
                // '|' => {
                //     return parseMultiLineComment(src, loc, diag);
                // },
                else => break,
            }
        }

        diag.*.result = .{ .unknownToken = loc };
        return Error.UnknownToken;
    }

    pub const ParseResult = struct {
        module: ModuleContext,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };

    // FIXME: force arena allocator?
    pub fn parse(
        in_alloc: std.mem.Allocator,
        src: []const u8,
        maybe_out_diagnostic: ?*Diagnostic,
    ) Error!ParseResult {
        var ignored_diagnostic: Diagnostic = undefined;
        const out_diag = if (maybe_out_diagnostic) |d| d else &ignored_diagnostic;
        out_diag.* = Diagnostic{ .source = src };

        var out_arena = std.heap.ArenaAllocator.init(in_alloc);
        errdefer out_arena.deinit();
        const out_alloc = out_arena.allocator();

        var local_arena = std.heap.ArenaAllocator.init(in_alloc);
        defer local_arena.deinit();
        const local_alloc = local_arena.allocator();

        // FIXME: make sure to reuse the hashing of the pool
        var label_map = std.AutoHashMapUnmanaged([*:0]const u8, struct {
            target: u32,
            loc: Loc,
        }){};
        // no defer; arena
        //defer label_map.deinit(in_alloc);

        var module = try ModuleContext.initCapacity(out_alloc, 256);
        // no defer; arena
        //errdefer module.deinit(out_alloc);

        var loc: Loc = .{};
        // TODO: store the the opener position and whether it's a quote
        var stack: std.SegmentedList(u32, 32) = .{};
        // uses local arena allocator, don't deinit
        //defer stack.deinit(alloc);

        // module at top of the stack
        try stack.append(local_alloc, 0);

        // if a label appears alone on a line, it becomes the "active" label and attaches to the next
        // parsed atom
        var active_label: ?[:0]const u8 = null;
        var last_sexp: ?u32 = null;

        const helper = struct {
            _stack: *@TypeOf(stack),
            _loc: *@TypeOf(loc),
            _last_sexp: *@TypeOf(last_sexp),
            _active_label: *@TypeOf(active_label),
            _label_map: *@TypeOf(label_map),
            _out_alloc: @TypeOf(out_alloc),
            _local_alloc: @TypeOf(local_alloc),
            _module: *@TypeOf(module),
            _out_diag: @TypeOf(out_diag),

            fn pushExistingSexp(self: *const @This(), index: u32) !void {
                // not reachable because invalidly trying to pop the module scope is handled
                const top = peek(self._stack) orelse unreachable;
                try self._module.get(top).value.list.append(self._out_alloc, index);
                self._last_sexp.* = index;

                if (self._active_label.*) |label| {
                    const put_res = try self._label_map.getOrPut(self._local_alloc, label.ptr);
                    if (put_res.found_existing) {
                        self._out_diag.result = Diagnostic.Result{ .duplicateLabel = .{
                            .first = put_res.value_ptr.loc,
                            .name = label,
                            .second = self._loc.*,
                        } };
                        return Diagnostic.Code.DuplicateLabel;
                    }

                    put_res.value_ptr.* = .{
                        .loc = self._loc.*,
                        .target = index,
                    };

                    self._active_label.* = null;
                }
            }

            fn pushSexp(self: *const @This(), in_sexp: Sexp) !void {
                const new_idx = try self._module.add(self._out_alloc, in_sexp);
                return self.pushExistingSexp(new_idx);
            }
        }{
            ._loc = &loc,
            ._stack = &stack,
            ._last_sexp = &last_sexp,
            ._active_label = &active_label,
            ._label_map = &label_map,
            ._out_alloc = out_alloc,
            ._local_alloc = local_alloc,
            ._module = &module,
            ._out_diag = out_diag,
        };

        while (loc.index < src.len) : (loc.increment(src)) {
            const c = src[loc.index];

            // std.debug.print("src=", .{});
            // std.json.encodeJsonString(src[loc.index..], .{}, std.io.getStdErr().writer()) catch unreachable;
            // std.debug.print("\n", .{});

            switch (c) {
                '-', '0'...'9' => {
                    const tok = try parseNumberOrUnaryNegationToken(src[loc.index..], loc, out_diag);
                    try helper.pushSexp(tok.sexp);
                    for (0..tok.src_span.len - 1) |_| loc.increment(src);
                },
                '(' => {
                    try stack.append(local_alloc, try module.add(out_alloc, .empty_list));
                },
                ')' => {
                    const old_top = stack.pop() orelse unreachable;
                    const new_top = peek(&stack) orelse {
                        out_diag.*.result = .{ .unmatchedCloser = loc };
                        return error.UnmatchedCloser;
                    };
                    try module.get(new_top).body().append(out_alloc, old_top);
                    last_sexp = old_top;
                },
                '"' => {
                    const tok = try parseStringToken(out_alloc, src[loc.index..], out_diag);
                    try helper.pushSexp(tok.sexp);
                    // unreachable cuz we'd have already failed if we popped the last one
                    for (0..tok.src_span.len - 1) |_| loc.increment(src);
                },
                '#' => {
                    // TODO: consider making all these token scanners
                    const tok = try parseHashStartedToken(src[loc.index..], loc, out_diag);
                    try helper.pushSexp(tok.sexp);
                    for (0..tok.src_span.len - 1) |_| loc.increment(src);
                },
                ';' => {
                    const comment = parseLineComment(src, loc);
                    // note we increment the newline which wasn't included
                    for (comment) |_| loc.increment(src);
                },
                // FIXME: temporarily this just returns an unquoted symbol
                '\'' => {
                    const tok = try parseSymbolToken(src[loc.index..], loc, out_diag);
                    try helper.pushSexp(tok.sexp);
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
                    const sym = pool.getSymbol(tok.src_span);
                    // might not be a symbol, could be a label jump or label
                    if (std.mem.startsWith(u8, sym, ">!")) {
                        // is label jump
                        const label_name = pool.getSymbol(tok.src_span[2..]);
                        if (label_map.getPtr(label_name.ptr)) |label_info| {
                            try helper.pushExistingSexp(label_info.target);
                        } else {
                            // FIXME: should be able to reference "eventual" labels
                            out_diag.result = Diagnostic.Result{ .unknownLabel = .{
                                .name = label_name,
                                .loc = loc,
                            } };
                            return Diagnostic.Code.UnknownLabel;
                        }
                    } else if (std.mem.startsWith(u8, sym, "<!")) {
                        // is label
                        const label_name = pool.getSymbol(tok.src_span[2..]);
                        if (last_sexp) |last| {
                            const put_res = try label_map.getOrPut(local_alloc, label_name.ptr);
                            if (put_res.found_existing) {
                                out_diag.result = Diagnostic.Result{ .duplicateLabel = .{
                                    .first = put_res.value_ptr.loc,
                                    .name = label_name,
                                    .second = loc,
                                } };
                                return Diagnostic.Code.DuplicateLabel;
                            }
                            put_res.value_ptr.* = .{
                                .target = last,
                                .loc = loc,
                            };
                        } else {
                            active_label = label_name;
                        }
                    } else {
                        // is regular symbol
                        try helper.pushSexp(tok.sexp);
                    }

                    for (0..tok.src_span.len - 1) |_| loc.increment(src);
                },
                ' ', '\t' => {},
                '\n' => {
                    last_sexp = null;
                },
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

        return ParseResult{
            .module = module,
            .arena = out_arena,
        };
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
    var expected = Sexp{ .value = .{ .module = std.ArrayListUnmanaged(u32).init(t.allocator) } };
    try expected.value.module.append(Sexp{ .value = .{ .int = 0 }, .label = "#!label1" });
    try expected.value.module.append(Sexp{ .value = .{ .int = 2 } });
    try expected.value.module.append(Sexp{ .value = .{ .ownedString = "hel\"lo\nworld" }, .label = "#!label2" });
    try expected.value.module.append(Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(t.allocator) }, .label = "#!label3" });
    try expected.value.module.items[3].value.list.append(Sexp{ .value = .{ .symbol = "+" } });
    try expected.value.module.items[3].value.list.append(Sexp{ .value = .{ .int = 3 } });
    try expected.value.module.items[3].value.list.append(Sexp{ .value = .{ .list = std.ArrayList(Sexp).init(t.allocator) } });
    try expected.value.module.items[3].value.list.items[2].value.list.append(Sexp{ .value = .{ .symbol = "-" } });
    try expected.value.module.items[3].value.list.items[2].value.list.append(Sexp{ .value = .{ .int = 210 } });
    try expected.value.module.items[3].value.list.items[2].value.list.append(Sexp{ .value = .{ .int = 5 } });
    try expected.value.module.append(syms.void);
    try expected.value.module.append(syms.true);
    try expected.value.module.append(syms.false);
    try expected.value.module.append(Sexp{ .value = .{ .symbol = "'sym" } });
    try expected.value.module.append(Sexp{ .value = .{ .ownedString = "" } });
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

test "parse factorial iterative with graph reference" {
    const a = t.allocator;

    // NOTE: without setting capacity, the get/add orders below will crash
    var module = try ModuleContext.initCapacity(a, 44);
    defer module.deinit(a);

    try module.getRoot().value.module.append(a, try module.add(a, try .emptyListCapacity(a, 5)));

    const def = module.getRoot().value.module.items[0];
    module.get(def).value.list.appendAssumeCapacity(try module.add(a, .symbol("define")));
    module.get(def).value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(a, 2)));
    module.get(def).value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(a, 3)));
    module.get(def).value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(a, 3)));
    module.get(def).value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(a, 3)));

    const func_decl = module.get(def).value.list.items[1];
    module.get(func_decl).value.list.appendAssumeCapacity(try module.add(a, .symbol("factorial")));
    module.get(func_decl).value.list.appendAssumeCapacity(try module.add(a, .symbol("n")));

    const var_type = module.get(def).value.list.items[2];
    module.get(var_type).value.list.appendAssumeCapacity(try module.add(a, .symbol("typeof")));
    module.get(var_type).value.list.appendAssumeCapacity(try module.add(a, .symbol("acc")));
    module.get(var_type).value.list.appendAssumeCapacity(try module.add(a, .symbol("i32")));

    const var_decl = module.get(def).value.list.items[3];
    module.get(var_decl).value.list.appendAssumeCapacity(try module.add(a, .symbol("define")));
    module.get(var_decl).value.list.appendAssumeCapacity(try module.add(a, .symbol("acc")));
    module.get(var_decl).value.list.appendAssumeCapacity(try module.add(a, .int(1)));

    const body = module.get(def).value.list.items[4];
    module.get(body).value.list.appendAssumeCapacity(try module.add(a, .symbol("begin")));
    module.get(body).value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(t.allocator, 4)));

    const @"if" = module.get(body).value.list.items[1];
    module.get(@"if").value.list.appendAssumeCapacity(try module.add(a, .symbol("if")));
    module.get(@"if").value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(t.allocator, 3)));
    module.get(@"if").value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(t.allocator, 2)));
    module.get(@"if").value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(t.allocator, 4)));

    const cond = module.get(@"if").value.list.items[1];
    module.get(cond).value.list.appendAssumeCapacity(try module.add(a, .symbol("<=")));
    module.get(cond).value.list.appendAssumeCapacity(try module.add(a, .symbol("n")));
    module.get(cond).value.list.appendAssumeCapacity(try module.add(a, .int(1)));

    const then = module.get(@"if").value.list.items[2];
    module.get(then).value.list.appendAssumeCapacity(try module.add(a, .symbol("begin")));
    module.get(then).value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(t.allocator, 2)));
    const then_return = module.get(then).value.list.items[1];
    module.get(then_return).value.list.appendAssumeCapacity(try module.add(a, .symbol("return")));
    module.get(then_return).value.list.appendAssumeCapacity(try module.add(a, .symbol("acc")));

    const @"else" = module.get(@"if").value.list.items[3];
    module.get(@"else").value.list.appendAssumeCapacity(try module.add(a, .symbol("begin")));
    module.get(@"else").value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(t.allocator, 3)));
    module.get(@"else").value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(t.allocator, 3)));
    module.get(@"else").value.list.appendAssumeCapacity(try module.add(a, .symbol(">!if"))); // TODO: different kind of symbol?

    const set_acc = module.get(@"else").value.list.items[1];
    module.get(set_acc).value.list.appendAssumeCapacity(try module.add(a, .symbol("set!")));
    module.get(set_acc).value.list.appendAssumeCapacity(try module.add(a, .symbol("acc")));
    module.get(set_acc).value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(t.allocator, 3)));
    const set_acc_expr = module.get(set_acc).value.list.items[2];
    module.get(set_acc_expr).value.list.appendAssumeCapacity(try module.add(a, .symbol("*")));
    module.get(set_acc_expr).value.list.appendAssumeCapacity(try module.add(a, .symbol("acc")));
    module.get(set_acc_expr).value.list.appendAssumeCapacity(try module.add(a, .symbol("n")));

    const set_n = module.get(@"else").value.list.items[2];
    module.get(set_n).value.list.appendAssumeCapacity(try module.add(a, .symbol("set!")));
    module.get(set_n).value.list.appendAssumeCapacity(try module.add(a, .symbol("n")));
    module.get(set_n).value.list.appendAssumeCapacity(try module.add(a, try .emptyListCapacity(t.allocator, 3)));
    const set_n_expr = module.get(set_n).value.list.items[2];
    module.get(set_n_expr).value.list.appendAssumeCapacity(try module.add(a, .symbol("-")));
    module.get(set_n_expr).value.list.appendAssumeCapacity(try module.add(a, .symbol("n")));
    module.get(set_n_expr).value.list.appendAssumeCapacity(try module.add(a, .int(1)));

    const source =
        \\(define (factorial n)
        \\  (typeof acc i64)
        \\  (define acc 1)
        \\  (begin
        \\    <!if
        \\    (if (<= n 1)
        \\        (begin (return acc))
        \\        (begin
        \\          (set! acc (* acc n))
        \\          (set! n (- n 1))
        \\          >!if))))
        \\
    ;

    var diag = Parser.Diagnostic{ .source = source };
    defer if (diag.result != .none) {
        std.debug.print("diag={}", .{diag});
    };
    var parsed = try Parser.parse(t.allocator, source, &diag);
    defer parsed.deinit();

    const result = module.getRoot().recursive_eq(parsed.module.getRoot(), &module);

    if (!result) {
        std.debug.print("====== ACTUAL ===========\n", .{});
        std.debug.print("{}\n", .{parsed.module});
        std.debug.print("====== EXPECTED =========\n", .{});
        std.debug.print("{}\n", .{module});
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
