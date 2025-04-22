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
const SymMapUnmanaged = @import("./InternPool.zig").SymMapUnmanaged;
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
            badValRef: Loc,
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
            BadValRef,
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
                .badValRef => |loc| {
                    return try writer.print(
                        \\Bad value reference at {}
                        \\  | {s}
                        \\    {}^
                    , .{
                        loc,
                        try loc.containing_line(self.source),
                        SpacePrint.init(loc.col - 1),
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
    };

    inline fn scanStringToken(alloc: std.mem.Allocator, src: []const u8, diag: *Diagnostic) Error!ParseTokenResult {
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
                            .sexp = Sexp{
                                .value = .{ .ownedString = try escapeStr(alloc, src[1..i]) },
                                .span = src[0 .. i + 1],
                            },
                        };
                    },
                },
                .escaped => state = .normal,
            }
        }

        diag.*.result = .{ .unterminatedString = src[0..] };
        return Error.UnterminatedString;
    }

    inline fn scanSymbolToken(src: []const u8, loc: Loc, diag: *Diagnostic) Error!ParseTokenResult {
        std.debug.assert(src.len > 0);
        const end = std.mem.indexOfAny(u8, src, &.{ ' ', '\n', '\t', ')' }) orelse src.len;
        const in_src_sym = src[0..end];
        if (in_src_sym.len == 0) {
            diag.result = .{ .emptyQuote = loc };
            return Error.EmptyQuote;
        }

        const sym = pool.getSymbol(in_src_sym);
        return ParseTokenResult{
            .sexp = Sexp{ .value = .{ .symbol = sym }, .span = in_src_sym },
        };
    }

    // TODO: support hex literals
    inline fn scanNumberOrUnaryNegationToken(src: []const u8, loc: Loc, diag: *Diagnostic) Error!ParseTokenResult {
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
                .sexp = Sexp{
                    .value = syms.@"-".value,
                    .span = src[0..1],
                },
            };

        const num_src = src[0..right_after];

        if (@intFromEnum(state) >= @intFromEnum(State.fraction)) {
            const res = std.fmt.parseFloat(f64, num_src) catch {
                diag.*.result = .{ .badFloat = num_src };
                return Error.BadFloat;
            };
            return .{
                .sexp = Sexp{ .value = .{ .float = res }, .span = num_src },
            };
        } else {
            const res = std.fmt.parseInt(i64, num_src, 10) catch {
                diag.*.result = .{ .badInteger = num_src };
                return Error.BadFloat;
            };
            return .{
                .sexp = Sexp{ .value = .{ .int = res }, .span = num_src },
            };
        }
    }

    inline fn scanLabelToken(src: []const u8, loc: Loc, diag: *Diagnostic) Error![]const u8 {
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

    inline fn scanMultiLineComment(src: []const u8, loc: Loc, diag: *Diagnostic) Error![]const u8 {
        std.debug.assert(src.len >= 2);
        const end = std.mem.indexOfPos(u8, src, 2, "|#") orelse {
            diag.result = .{ .unknownToken = loc };
            return Error.UnterminatedString;
        };
        _ = end;
    }

    inline fn scanLineComment(whole_src: []const u8, loc: Loc) []const u8 {
        const rest = whole_src[loc.index..];
        std.debug.assert(rest.len >= 1);
        const end = std.mem.indexOfScalarPos(u8, rest, 1, '\n') orelse rest.len;
        // NOTE: we do not include the new line
        return rest[0..end];
    }

    inline fn scanHashStartedToken(
        src: []const u8,
        loc: Loc,
        diag: *Diagnostic,
        label_map: *SymMapUnmanaged(LabelEntry),
    ) Error!ParseTokenResult {
        std.debug.assert(src.len >= 1);

        for (src[1..]) |c| {
            switch (c) {
                // TODO: remove these... I don't "true" and "false" only in graphlt
                't' => {
                    if (src.len > 2) switch (src[2]) {
                        ' ', '\n', '\t', ')' => {},
                        else => break,
                    };
                    return .{
                        .sexp = .{
                            .value = syms.true.value,
                            .span = src[0..2],
                        },
                    };
                },
                'f' => {
                    if (src.len > 2) switch (src[2]) {
                        ' ', '\n', '\t', ')' => {},
                        else => break,
                    };
                    return .{
                        .sexp = .{
                            .value = syms.false.value,
                            .span = src[0..2],
                        },
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
                        .sexp = .{
                            .value = syms.void.value,
                            .span = src[0..5],
                        },
                    };
                },
                '!' => {
                    const end_index = std.mem.indexOfAnyPos(u8, src, 2, &.{ ' ', '\n', '\t', ')' }) orelse src.len;

                    const label = src[2..end_index];

                    if (label_map.getPtr(pool.getSymbol(label))) |label_info| {
                        return .{
                            .sexp = .{
                                .span = src[0 .. "#!".len + label.len],
                                .value = .{ .valref = .{
                                    .target = label_info.target,
                                } },
                            },
                        };
                    } else {
                        // FIXME: should be able to reference "eventual" labels
                        diag.result = Diagnostic.Result{ .unknownLabel = .{
                            .name = label,
                            .loc = loc,
                        } };
                        return Diagnostic.Code.UnknownLabel;
                    }
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

    pub const ParseResult = struct {
        module: ModuleContext,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };

    const LabelEntry = struct {
        target: u32,
        loc: Loc,
    };

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

        var label_map = SymMapUnmanaged(LabelEntry){};
        // no defer; arena
        //defer label_map.deinit(in_alloc);

        var module = try ModuleContext.initCapacity(in_alloc, 256);
        module.source = src;
        defer module.deinit();

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

            fn pushAllocedSexp(self: *const @This(), index: u32) !void {
                // not reachable because invalidly trying to pop the module scope is handled
                const top = peek(self._stack) orelse unreachable;
                try self._module.get(top).body().append(self._out_alloc, index);
                self._last_sexp.* = index;

                if (self._active_label.*) |label| {
                    self._module.get(index).label = label;

                    const put_res = try self._label_map.getOrPut(self._local_alloc, label);
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
                const new_idx = try self._module.add(in_sexp);
                return self.pushAllocedSexp(new_idx);
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
                    const tok = try scanNumberOrUnaryNegationToken(src[loc.index..], loc, out_diag);
                    try helper.pushSexp(tok.sexp);
                    for (0..tok.sexp.span.?.len - 1) |_| loc.increment(src);
                },
                '(' => {
                    const added = try module.add(.empty_list);

                    if (active_label) |label| {
                        module.get(added).label = label;

                        const put_res = try label_map.getOrPut(local_alloc, label);
                        if (put_res.found_existing) {
                            out_diag.result = Diagnostic.Result{ .duplicateLabel = .{
                                .first = put_res.value_ptr.loc,
                                .name = label,
                                .second = loc,
                            } };
                            return Diagnostic.Code.DuplicateLabel;
                        }

                        put_res.value_ptr.* = .{
                            .loc = loc,
                            .target = added,
                        };

                        active_label = null;
                    }

                    try stack.append(local_alloc, added);
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
                    const tok = try scanStringToken(out_alloc, src[loc.index..], out_diag);
                    try helper.pushSexp(tok.sexp);
                    // unreachable cuz we'd have already failed if we popped the last one
                    for (0..tok.sexp.span.?.len - 1) |_| loc.increment(src);
                },
                '#' => {
                    // TODO: consider making all these token scanners
                    const tok = try scanHashStartedToken(src[loc.index..], loc, out_diag, &label_map);
                    try helper.pushSexp(tok.sexp);
                    for (0..tok.sexp.span.?.len - 1) |_| loc.increment(src);
                },
                ';' => {
                    const comment = scanLineComment(src, loc);
                    // note we increment the newline which wasn't included
                    for (comment) |_| loc.increment(src);
                },
                // FIXME: temporarily this just returns an unquoted symbol
                '\'' => {
                    const tok = try scanSymbolToken(src[loc.index..], loc, out_diag);
                    try helper.pushSexp(tok.sexp);
                    for (0..tok.sexp.span.?.len - 1) |_| loc.increment(src);
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
                    const tok = try scanSymbolToken(src[loc.index..], loc, out_diag);
                    const sym = pool.getSymbol(tok.sexp.span.?);
                    // might not be a symbol, could be a label jump or label
                    if (std.mem.startsWith(u8, sym, ">!")) {
                        // is label jump
                        const label_name = pool.getSymbol(tok.sexp.span.?[2..]);
                        if (label_map.getPtr(label_name)) |label_info| {
                            try helper.pushSexp(Sexp{
                                .span = sym,
                                .value = .{ .jump = .{
                                    .name = pool.getSymbol(sym[2..]),
                                    .target = label_info.target,
                                } },
                            });
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
                        const label_name = pool.getSymbol(tok.sexp.span.?[2..]);
                        if (last_sexp) |last| {
                            module.get(last).label = label_name;
                            const put_res = try label_map.getOrPut(local_alloc, label_name);
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

                    for (0..tok.sexp.span.?.len - 1) |_| loc.increment(src);
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

        const out_mod_arena = std.ArrayListUnmanaged(Sexp).fromOwnedSlice(try out_alloc.dupe(Sexp, module.arena.items));
        module.arena.clearRetainingCapacity();

        return ParseResult{
            .module = ModuleContext{
                .source = module.source,
                .arena = out_mod_arena,
                ._alloc = out_alloc,
            },
            .arena = out_arena,
        };
    }
};

test "parseNumberOrUnaryNegationToken" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Parser.Diagnostic = .{ .source = undefined };
    const loc: Loc = undefined;

    try std.testing.expectEqual(0, (try Parser.scanNumberOrUnaryNegationToken("0 ", loc, &diag)).sexp.value.int);
    try std.testing.expectEqual(1, (try Parser.scanNumberOrUnaryNegationToken("1 ", loc, &diag)).sexp.value.int);
    try std.testing.expectEqual(1, (try Parser.scanNumberOrUnaryNegationToken("1", loc, &diag)).sexp.value.int);
    try std.testing.expectEqual(-3, (try Parser.scanNumberOrUnaryNegationToken("-3", loc, &diag)).sexp.value.int);
    try std.testing.expectEqual(syms.@"-", (try Parser.scanNumberOrUnaryNegationToken("-", loc, &diag)).sexp);
    try std.testing.expectEqual(1000, (try Parser.scanNumberOrUnaryNegationToken("1000)", loc, &diag)).sexp.value.int);
    try std.testing.expectEqual(1.5e+2, (try Parser.scanNumberOrUnaryNegationToken("1.5e+2", loc, &diag)).sexp.value.float);
    try std.testing.expectEqual(-0.5e-2, (try Parser.scanNumberOrUnaryNegationToken("-0.5e-2", loc, &diag)).sexp.value.float);
    try std.testing.expectEqual(1.2340002e5, (try Parser.scanNumberOrUnaryNegationToken("1.2340002e5", loc, &diag)).sexp.value.float);
    // NOTE: in lisps, space is the only token separator, -0/ is not a number but it isn't an unknown token necessarily
    try std.testing.expectError(Parser.Error.UnknownToken, Parser.scanNumberOrUnaryNegationToken("-0/", loc, &diag));
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
    var mod = try ModuleContext.initCapacity(t.allocator, 16);
    defer mod.deinit();

    const label1_idx = try mod.addToRoot(Sexp{ .value = .{ .int = 0 }, .label = pool.getSymbol("label1") });
    _ = try mod.addToRoot(Sexp{ .value = .{ .int = 2 } });
    _ = try mod.addToRoot(Sexp{ .value = .{ .ownedString = "hel\"lo\nworld" }, .label = pool.getSymbol("label2") });
    const list_idx = try mod.addToRoot(try .emptyListCapacity(mod.alloc(), 3));
    const list = mod.get(list_idx);
    list.label = pool.getSymbol("label3");
    list.value.list.appendAssumeCapacity(try mod.add(.symbol("+")));
    list.value.list.appendAssumeCapacity(try mod.add(Sexp{ .value = .{ .int = 3 } }));
    list.value.list.appendAssumeCapacity(try mod.add(try .emptyListCapacity(t.allocator, 3)));
    const sublist = mod.get(list.value.list.items[2]);
    sublist.value.list.appendAssumeCapacity(try mod.add(.symbol("-")));
    sublist.value.list.appendAssumeCapacity(try mod.add(Sexp{ .value = .{ .int = 210 } }));
    sublist.value.list.appendAssumeCapacity(try mod.add(Sexp{ .value = .{ .int = 5 } }));
    _ = try mod.addToRoot(syms.void);
    _ = try mod.addToRoot(syms.true);
    _ = try mod.addToRoot(syms.false);
    _ = try mod.addToRoot(.symbol("'sym"));
    _ = try mod.addToRoot(Sexp{ .value = .{ .ownedString = "" } });
    _ = try mod.addToRoot(.valref(.{ .target = label1_idx }));

    const expected = mod.getRoot();

    const source =
        \\<!label1
        \\0
        \\
        \\2
        \\"hel\"lo
        \\world" <!label2 ;; comment
        \\(+ 3 (- 210 5)
        \\) <!label3
        \\#void
        \\#t
        \\#f
        \\'sym
        \\""
        \\#!label1
    ;

    var diag = Parser.Diagnostic{ .source = source };
    defer if (diag.result != .none) {
        std.debug.print("diag={}", .{diag});
    };

    var actual = try Parser.parse(t.allocator, source, &diag);
    defer actual.deinit();

    const result = expected.recursive_eq(&mod, actual.module.getRoot(), &actual.module);

    if (!result) {
        std.debug.print("====== ACTUAL ===========\n", .{});
        std.debug.print("{}\n", .{actual.module});
        std.debug.print("====== EXPECTED =========\n", .{});
        std.debug.print("{}\n", .{mod});
        std.debug.print("=========================\n", .{});
    }

    try t.expect(result);
}

test "parse factorial iterative with graph reference" {
    const a = t.allocator;

    // NOTE: without setting capacity, the get/add orders below will crash
    var module = try ModuleContext.initCapacity(a, 45);
    defer module.deinit();

    try module.getRoot().value.module.append(a, try module.add(try .emptyListCapacity(a, 6)));

    const def = module.getRoot().value.module.items[0];
    module.get(def).value.list.appendAssumeCapacity(try module.add(.symbol("define")));
    module.get(def).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(a, 2)));
    module.get(def).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(a, 3)));
    module.get(def).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(a, 3)));
    module.get(def).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(a, 3)));

    const func_decl = module.get(def).value.list.items[1];
    module.get(func_decl).value.list.appendAssumeCapacity(try module.add(.symbol("factorial")));
    module.get(func_decl).value.list.appendAssumeCapacity(try module.add(.symbol("n")));

    const var_type = module.get(def).value.list.items[2];
    module.get(var_type).value.list.appendAssumeCapacity(try module.add(.symbol("typeof")));
    module.get(var_type).value.list.appendAssumeCapacity(try module.add(.symbol("acc")));
    module.get(var_type).value.list.appendAssumeCapacity(try module.add(.symbol("i64")));

    const var_decl = module.get(def).value.list.items[3];
    module.get(var_decl).value.list.appendAssumeCapacity(try module.add(.symbol("define")));
    module.get(var_decl).value.list.appendAssumeCapacity(try module.add(.symbol("acc")));
    module.get(var_decl).value.list.appendAssumeCapacity(try module.add(.int(1)));

    const body = module.get(def).value.list.items[4];
    module.get(body).value.list.appendAssumeCapacity(try module.add(.symbol("begin")));
    module.get(body).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 4)));

    const @"if" = module.get(body).value.list.items[1];
    module.get(@"if").label = pool.getSymbol("if");
    module.get(@"if").value.list.appendAssumeCapacity(try module.add(.symbol("if")));
    module.get(@"if").value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 3)));
    module.get(@"if").value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 2)));
    module.get(@"if").value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 4)));

    const cond = module.get(@"if").value.list.items[1];
    module.get(cond).value.list.appendAssumeCapacity(try module.add(.symbol("<=")));
    module.get(cond).value.list.appendAssumeCapacity(try module.add(.symbol("n")));
    module.get(cond).value.list.appendAssumeCapacity(try module.add(.int(1)));

    const then = module.get(@"if").value.list.items[2];
    module.get(then).value.list.appendAssumeCapacity(try module.add(.symbol("begin")));
    module.get(then).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 2)));
    const then_return = module.get(then).value.list.items[1];
    module.get(then_return).value.list.appendAssumeCapacity(try module.add(.symbol("return")));
    module.get(then_return).value.list.appendAssumeCapacity(try module.add(.symbol("acc")));

    const @"else" = module.get(@"if").value.list.items[3];
    module.get(@"else").value.list.appendAssumeCapacity(try module.add(.symbol("begin")));
    module.get(@"else").value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 3)));
    module.get(@"else").value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 3)));
    module.get(@"else").value.list.appendAssumeCapacity(try module.add(Sexp{ .value = .{ .jump = .{
        .name = pool.getSymbol("if"),
        .target = @"if",
    } } }));

    const set_acc = module.get(@"else").value.list.items[1];
    module.get(set_acc).value.list.appendAssumeCapacity(try module.add(.symbol("set!")));
    module.get(set_acc).value.list.appendAssumeCapacity(try module.add(.symbol("acc")));
    module.get(set_acc).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 3)));
    const set_acc_expr = module.get(set_acc).value.list.items[2];
    module.get(set_acc_expr).value.list.appendAssumeCapacity(try module.add(.symbol("*")));
    module.get(set_acc_expr).value.list.appendAssumeCapacity(try module.add(.symbol("acc")));
    module.get(set_acc_expr).value.list.appendAssumeCapacity(try module.add(.symbol("n")));

    const set_n = module.get(@"else").value.list.items[2];
    module.get(set_n).value.list.appendAssumeCapacity(try module.add(.symbol("set!")));
    module.get(set_n).value.list.appendAssumeCapacity(try module.add(.symbol("n")));
    module.get(set_n).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 3)));
    const set_n_expr = module.get(set_n).value.list.items[2];
    module.get(set_n_expr).value.list.appendAssumeCapacity(try module.add(.symbol("-")));
    module.get(set_n_expr).value.list.appendAssumeCapacity(try module.add(.symbol("n")));
    module.get(set_n_expr).value.list.appendAssumeCapacity(try module.add(.int(1)));

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

    const result = Sexp.recursive_eq(
        module.getRoot(),
        &module,
        parsed.module.getRoot(),
        &parsed.module,
    );

    const jump_idx = parsed.module.get( // >!if
        parsed.module.get( // else
            parsed.module.get( // (if
                parsed.module.get( // (begin
                    parsed.module.getRoot().value.module.items[0] //(define
                ).value.list.items[4] //
            ).value.list.items[1] //
        ).value.list.items[3] //
    ).value.list.items[3];

    const jump = parsed.module.get(jump_idx);

    try std.testing.expectEqual(.jump, std.meta.activeTag(jump.value));

    if (!result) {
        std.debug.print("====== ACTUAL ===========\n", .{});
        std.debug.print("{}\n", .{parsed.module});
        std.debug.print("====== EXPECTED =========\n", .{});
        std.debug.print("{}\n", .{module});
        std.debug.print("=========================\n", .{});
    }

    try t.expect(result);
}

test "parse label" {
    const a = t.allocator;

    // NOTE: without setting capacity, the get/add orders below will crash
    var module = try ModuleContext.initCapacity(a, 44);
    defer module.deinit();

    try module.getRoot().value.module.append(a, try module.add(try .emptyListCapacity(a, 5)));

    const def = module.getRoot().value.module.items[0];
    module.get(def).value.list.appendAssumeCapacity(try module.add(.symbol("define")));
    module.get(def).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(a, 3)));
    module.get(def).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(a, 3)));

    const func_decl = module.get(def).value.list.items[1];
    module.get(func_decl).value.list.appendAssumeCapacity(try module.add(.symbol("foo")));
    module.get(func_decl).value.list.appendAssumeCapacity(try module.add(.symbol("a")));
    module.get(func_decl).value.list.appendAssumeCapacity(try module.add(.symbol("b")));

    const body = module.get(def).value.list.items[2];
    module.get(body).value.list.appendAssumeCapacity(try module.add(.symbol("begin")));
    module.get(body).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 3)));
    module.get(body).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 3)));

    const x = module.get(body).value.list.items[1];
    module.get(x).label = pool.getSymbol("x");
    module.get(x).value.list.appendAssumeCapacity(try module.add(.symbol("*")));
    module.get(x).value.list.appendAssumeCapacity(try module.add(.float(0.5)));
    module.get(x).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 3)));

    const add = module.get(x).value.list.items[2];
    module.get(add).value.list.appendAssumeCapacity(try module.add(.symbol("+")));
    module.get(add).value.list.appendAssumeCapacity(try module.add(.symbol("a")));
    module.get(add).value.list.appendAssumeCapacity(try module.add(.symbol("b")));

    const div_res = module.get(body).value.list.items[2];
    module.get(div_res).value.list.appendAssumeCapacity(try module.add(.symbol("/")));
    module.get(div_res).value.list.appendAssumeCapacity(try module.add(try .emptyListCapacity(t.allocator, 2)));
    module.get(div_res).value.list.appendAssumeCapacity(try module.add(.symbol("#!x")));

    const sqr = module.get(div_res).value.list.items[1];
    module.get(sqr).value.list.appendAssumeCapacity(try module.add(.symbol("sqr")));
    module.get(sqr).value.list.appendAssumeCapacity(try module.add(.symbol("#!x")));

    const source =
        \\(define (foo a b)
        \\  (begin
        \\    (* 0.5 (+ a b)) <!x
        \\    (/ (sqr #!x) #!x)))
        \\
    ;

    var diag = Parser.Diagnostic{ .source = source };
    defer if (diag.result != .none) {
        std.debug.print("diag={}", .{diag});
    };
    var parsed = try Parser.parse(t.allocator, source, &diag);
    defer parsed.deinit();

    const result = Sexp.recursive_eq(
        module.getRoot(),
        &module,
        parsed.module.getRoot(),
        &parsed.module,
    );

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
    var parsed = Parser.parse(t.allocator, source, &diagnostic);
    defer {
        if (parsed) |*val| {
            val.deinit();
        } else |_| {}
    }
    try t.expectError(error.UnmatchedCloser, parsed);

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
    var parsed = Parser.parse(t.allocator, source, &diagnostic);
    defer {
        if (parsed) |*val| {
            val.deinit();
        } else |_| {}
    }
    try t.expectError(error.UnmatchedOpener, parsed);

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
    var actual = Parser.parse(t.allocator, source, null);
    defer {
        if (actual) |*a| a.deinit() else |_| {}
    }
    try t.expectError(error.UnmatchedCloser, actual);
}
