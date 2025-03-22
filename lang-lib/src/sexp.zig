const std = @import("std");
const builtin = @import("builtin");
const FileBuffer = @import("./FileBuffer.zig");
const PageWriter = @import("./PageWriter.zig").PageWriter;
const io = std.io;
const testing = std.testing; // TODO: consolidate
const t = std.testing;
const json = std.json;
const pool = &@import("./InternPool.zig").pool;
const Parser = @import("./sexp_parser.zig").Parser;

// FIXME: don't include in non-debug builds

fn _print_sexp(sexp: *const Sexp) callconv(.C) void {
    std.debug.print("{}\n", .{sexp});
}

comptime {
    if (builtin.target.cpu.arch != .wasm32 and builtin.mode == .Debug) {
        @export(&_print_sexp, .{ .name = "_print_sexp", .linkage = .strong });
    }
}

// FIXME:
// - this should be data-oriented
// - u32 indices instead of pointers
//
// consider making `.x` a special syntax which accesses .x from an object

// TODO: add an init function that initializes the root for you
pub const ModuleContext = struct {
    // TODO: rename from arena, which means something else in zig
    arena: std.ArrayListUnmanaged(Sexp) = .{},

    pub inline fn add(self: *@This(), alloc: std.mem.Allocator, sexp: Sexp) !u32 {
        try self.arena.append(alloc, sexp);
        return @intCast(self.arena.items.len - 1);
    }

    pub inline fn get(self: *const @This(), index: u32) *Sexp {
        return &self.arena.items[index];
    }


    pub inline fn getRoot(self: *const @This()) *Sexp {
        return self.get(0);
    }

    pub fn init(alloc: std.mem.Allocator) !@This() {
        return initCapacity(alloc, 1);
    }

    pub fn initCapacity(alloc: std.mem.Allocator, capacity: usize) !@This() {
        var arena = try std.ArrayListUnmanaged(Sexp).initCapacity(alloc, capacity);
        arena.appendAssumeCapacity(try .emptyModuleCapacity(alloc, capacity - 1));

        return @This(){
            .arena = arena,
        };
    }


    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.getRoot().deinit(self, alloc);
        self.arena.deinit(alloc);
    }

    pub fn format(self: *const @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var emitted_labels = std.AutoHashMap([*:0]const u8, void).init(arena.allocator());

        _ = try self.getRoot()._write(self, writer, .{
            .emitted_labels = &emitted_labels,
        }, .{});
    }
};

/// modules and lists contain u32 indices into a ModuleContext's arena
pub const Sexp = struct {
    comment: ?[]const u8 = null,
    /// optional text span, when parsed from a source file, mostly for diagnostics
    span: ?[]const u8 = null,
    /// optional label
    label: ?[:0]const u8 = null,
    value: union(enum) {
        /// holds indices into the arena
        module: std.ArrayListUnmanaged(u32),
        /// holds indices into the arena
        list: std.ArrayListUnmanaged(u32),
        void,
        int: i64,
        float: f64,
        bool: bool,
        // FIXME: consoliate these
        /// this Sexp owns the referenced memory, it must be freed
        ownedString: []const u8,
        /// this Sexp is borrowing the referenced memory, it should not be freed
        borrowedString: []const u8,
        /// always in the intern pool
        symbol: [:0]const u8,
        // TODO: quote/quasiquote, etc
    },

    const Self = @This();

    fn _deinit(
        self: *@This(),
        mod_ctx: *const ModuleContext,
        alloc: std.mem.Allocator,
        visited: *std.AutoHashMap(*const Sexp, void),
    ) void {
        if (visited.contains(self))
            return;
        visited.put(self, {}) catch unreachable;
        switch (self.value) {
            .ownedString => |v| {
                alloc.free(v);
            },
            .list, .module => |*v| {
                for (v.items) |item_idx| {
                    const item = &mod_ctx.arena.items[item_idx];
                    item._deinit(mod_ctx, alloc, visited);
                }
                v.deinit(alloc);
            },
            .void, .int, .float, .bool, .borrowedString, .symbol => {},
        }
    }


    pub fn deinit(self: *@This(), mod_ctx: *const ModuleContext, alloc: std.mem.Allocator) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var visited = std.AutoHashMap(*const Sexp, void).init(arena.allocator());
        defer visited.deinit();

        return self._deinit(mod_ctx, alloc, &visited);
    }

    pub fn emptyList() Sexp {
        return Sexp{ .value = .{ .list = .empty } };
    }

    pub const empty_list = Sexp{ .value = .{ .list = .empty } };

    pub fn emptyListCapacity(alloc: std.mem.Allocator, capacity: usize) !Sexp {
        return Sexp{ .value = .{ .list = try std.ArrayListUnmanaged(u32).initCapacity(alloc, capacity) } };
    }

    pub fn symbol(sym: [:0]const u8) Sexp {
        return Sexp{ .value = .{ .symbol = pool.getSymbol(sym) } };
    }

    pub fn int(value: i64) Sexp {
        return Sexp{ .value = .{ .int = value } };
    }


    pub fn emptyModule() Sexp {
        return Sexp{ .value = .{ .module = .empty } };
    }

    pub fn emptyModuleCapacity(alloc: std.mem.Allocator, capacity: usize) !Sexp {
        return Sexp{ .value = .{ .module = try std.ArrayListUnmanaged(u32).initCapacity(alloc, capacity) } };
    }

    pub fn body(self: *Self) *std.ArrayListUnmanaged(u32) {
        return switch (self.value) {
            .list, .module => |*v| v,
            .ownedString, .void, .int, .float, .bool, .borrowedString, .symbol => @panic("can only call 'body' on modules and lists"),
        };
    }

    pub fn getWithModule(self: *const Self, index: usize, mod_ctx: *const ModuleContext) *Sexp {
        return switch (self.value) {
            .list, .module => |*v| mod_ctx.get(v.items[index]),
            .ownedString, .void, .int, .float, .bool, .borrowedString, .symbol => @panic("can only call 'getWithModule' on modules and lists"),
        };
    }

    pub fn toOwnedSlice(self: *Self) ![]Sexp {
        return switch (self.value) {
            .list, .module => |*v| v.toOwnedSlice(),
            .ownedString, .void, .int, .float, .bool, .borrowedString, .symbol => @panic("can only call toOwnedSlice on modules and lists"),
        };
    }

    const WriteState = struct {
        /// number of spaces we are in
        depth: usize = 0,
        emitted_labels: *std.AutoHashMap([*:0]const u8, void),
    };

    fn writeModule(mod_ctx: *const ModuleContext, form: *const std.ArrayListUnmanaged(u32), writer: anytype, state: WriteState, comptime opts: WriteOptions) @TypeOf(writer).Error!WriteState {
        for (form.items, 0..) |item_idx, i| {
            if (i != 0) _ = try writer.write("\n");
            const item = &mod_ctx.arena.items[item_idx];
            try writer.writeByteNTimes(' ', state.depth);
            _ = try item._write(mod_ctx, writer, .{ .depth = state.depth, .emitted_labels = state.emitted_labels }, opts);
        }

        return .{ .depth = 0, .emitted_labels = state.emitted_labels };
    }

    fn writeList(mod_ctx: *const ModuleContext, form: *const std.ArrayListUnmanaged(u32), writer: anytype, state: WriteState, comptime opts: WriteOptions) @TypeOf(writer).Error!WriteState {
        var depth: usize = 0;

        depth += try writer.write("(");

        if (form.items.len >= 1) {
            depth += (try mod_ctx.arena.items[form.items[0]]._write(mod_ctx, writer, .{ .depth = state.depth + depth, .emitted_labels = state.emitted_labels }, opts,)).depth;
        }

        if (form.items.len >= 2) {
            depth += try writer.write(" ");

            _ = try mod_ctx.arena.items[form.items[1]]._write(mod_ctx, writer, .{ .depth = state.depth + depth, .emitted_labels = state.emitted_labels }, opts);

            for (form.items[2..]) |item_idx| {
                const item = &mod_ctx.arena.items[item_idx];
                _ = try writer.write("\n");
                try writer.writeByteNTimes(' ', state.depth + depth);
                _ = try item._write(mod_ctx, writer, .{ .depth = state.depth + depth, .emitted_labels = state.emitted_labels }, opts);
            }
        }

        _ = try writer.write(")");

        return .{ .depth = depth, .emitted_labels = state.emitted_labels, };
    }

    // eventually we want to format special forms specially
    const SpecialWriter = struct {
        pub fn @"if"(self: *const Self, writer: anytype, state: WriteState) @TypeOf(writer).Error!WriteState {
            _ = self;
            return state;
        }

        pub fn begin(self: *const Self, writer: anytype, state: WriteState) @TypeOf(writer).Error!WriteState {
            _ = self;
            return state;
        }
    };

    fn _write(self: *const Self, mod_ctx: *const ModuleContext, writer: anytype, state: WriteState, comptime opts: WriteOptions) @TypeOf(writer).Error!WriteState {
        if (self.label) |label| {
            if (state.emitted_labels.contains(label.ptr)) {
                _ = try writer.write(">!");
                _ = try writer.write(label);
                return .{
                    .depth = ">!".len + label.len,
                    .emitted_labels = state.emitted_labels,
                };
            } else {
                // FIXME: handle OOM better
                state.emitted_labels.put(label.ptr, {}) catch unreachable;
                _ = try writer.write("\n");
                _ = try writer.writeByteNTimes(' ', state.depth);
                _ = try writer.write("<!");
                _ = try writer.write(label);
                _ = try writer.write("\n");
                _ = try writer.writeByteNTimes(' ', state.depth);
            }
        }

        // TODO: calculate stack space requirements?
        const write_state_or_err: @TypeOf(writer).Error!WriteState = switch (self.value) {
            .module => |v| writeModule(mod_ctx, &v, writer, state, opts),
            .list => |v| writeList(mod_ctx, &v, writer, state, opts),
            inline .float, .int => |v| _: {
                var counting_writer = std.io.countingWriter(writer);
                try counting_writer.writer().print("{d}", .{v});
                break :_ .{ .depth = @intCast(counting_writer.bytes_written), .emitted_labels = state.emitted_labels };
            },
            .bool => |v| _: {
                _ = try writer.write(if (v) syms.true.value.symbol else syms.false.value.symbol);
                std.debug.assert(syms.true.value.symbol.len == syms.false.value.symbol.len);
                break :_ .{ .depth = syms.true.value.symbol.len, .emitted_labels = state.emitted_labels };
            },
            .void => _: {
                _ = try writer.write(syms.void.value.symbol);
                break :_ .{ .depth = syms.void.value.symbol.len, .emitted_labels = state.emitted_labels };
            },
            .ownedString, .borrowedString => |v| _: {
                // able to specify via formating params
                var cw = std.io.countingWriter(writer);
                switch (opts.string_literal_dialect) {
                    .json => {
                        try json.encodeJsonString(v, .{}, cw.writer());
                    },
                    .simple => {
                        try cw.writer().writeByte('"');
                        for (v) |c| switch (c) {
                            '"' => try cw.writer().writeAll("\\\""),
                            else => try cw.writer().writeByte(c),
                        };
                        try cw.writer().writeByte('"');
                    },
                    // FIXME: use writeWatMemoryString?
                    .wat => {
                        try cw.writer().writeByte('"');
                        try cw.writer().writeAll(v);
                        try cw.writer().writeByte('"');
                    },
                }
                break :_ .{ .depth = @intCast(cw.bytes_written + 2), .emitted_labels = state.emitted_labels };
            },
            .symbol => |v| _: {
                try writer.print("{s}", .{v});
                break :_ .{ .depth = v.len, .emitted_labels = state.emitted_labels };
            },
        };

        return try write_state_or_err;
    }

    const WriteOptions = struct {
        string_literal_dialect: enum {
            json,
            wat,
            // HACK: backslashes can't be escaped cuz this sucks. Temporary to make encoding
            // WAT easier
            /// only escape quotes, not even backslashes
            simple,
        } = .simple,
    };

    pub fn write(self: *const Self, mod_ctx: *const ModuleContext, writer: anytype, comptime options: WriteOptions) !usize {
        var counting_writer = std.io.countingWriter(writer);
        _ = try self._write(mod_ctx, counting_writer.writer(), .{}, options);
        return @intCast(counting_writer.bytes_written);
    }

    pub fn _recursive_eq(
        self: *const Self,
        lctx: *ModuleContext,
        other: *const Self,
        rctx: *ModuleContext,
        lvisited: *std.AutoHashMap(*const Sexp, void),
    ) bool {
        if (lvisited.contains(self)) return true;
        lvisited.put(self, {}) catch unreachable;

        if (std.meta.activeTag(self.value) != std.meta.activeTag(other.value)) {
            return false;
        }

        if ((self.comment == null) != (other.comment == null))
            return false;

        if (!std.meta.eql(self.comment, other.comment))
            return false;

        if ((self.label == null) != (other.label == null))
            return false;

        if (self.label != null and self.label.?.ptr != other.label.?.ptr)
            return false;

        switch (self.value) {
            .float => |v| return v == other.value.float,
            .bool => |v| return v == other.value.bool,
            .void => return true,
            .int => |v| return v == other.value.int,
            .ownedString => |v| return std.mem.eql(u8, v, other.value.ownedString),
            .borrowedString => |v| return std.mem.eql(u8, v, other.value.borrowedString),
            .symbol => |v| return std.mem.eql(u8, v, other.value.symbol),
            inline .module, .list => |v, sexp_type| {
                const other_list = @field(other.value, @tagName(sexp_type));
                if (v.items.len != other_list.items.len) {
                    return false;
                }
                for (v.items, other_list.items) |item_idx, other_item_idx| {
                    const item = lctx.get(item_idx);
                    const other_item = rctx.get(other_item_idx);
                    if (!_recursive_eq(item, lctx, other_item, rctx, lvisited))
                        return false;
                }
                return true;
            },
        }
    }

    fn _findPatternMismatch(
        self_index: u32,
        lctx: *const ModuleContext,
        pat_index: u32,
        pctx: *const ModuleContext,
        lvisited: *std.AutoHashMap(u32, void),
    ) ?u32 {
        // FIXME: make sure this is correct...
        if (lvisited.contains(self_index)) return null;
        lvisited.put(self_index, {}) catch unreachable;

        const self: *const Sexp = lctx.get(self_index);
        const pattern: *const Sexp = pctx.get(pat_index);

        if (pattern.value == .symbol and pattern.value.symbol.ptr == pool.getSymbol("ANY").ptr) {
            return null;
        }

        if (pattern.value == .symbol and pattern.value.symbol.ptr == pool.getSymbol("SYMBOL").ptr) {
            return if (self.value == .symbol) null else self_index;
        }

        if (std.meta.activeTag(self.value) != std.meta.activeTag(pattern.value)) {
            return self_index;
        }

        if ((self.label == null) != (pattern.label == null))
            return self_index;

        if (self.label != null and self.label.?.ptr != pattern.label.?.ptr)
            return self_index;

        switch (self.value) {
            .float => |v| return if (v == pattern.value.float) null else self_index,
            .bool => |v| return if (v == pattern.value.bool) null else self_index,
            .void => return null,
            .int => |v| return if (v == pattern.value.int) null else self_index,
            .ownedString => |v| return if (std.mem.eql(u8, v, pattern.value.ownedString)) null else self_index,
            .borrowedString => |v| return if (std.mem.eql(u8, v, pattern.value.borrowedString)) null else self_index,
            // TODO: it's pooled, can do a cheaper comparison
            .symbol => |v| return if (std.mem.eql(u8, v, pattern.value.symbol)) null else self_index,
            inline .module, .list => |v, sexp_type| {
                const pattern_list = @field(pattern.value, @tagName(sexp_type));
                var i: usize = 0;
                outer: while (i < v.items.len and i < pattern_list.items.len) : (i += 1) {
                    const item_idx = v.items[i];
                    const pattern_item_idx = pattern_list.items[i];
                    const pattern_item = pctx.get(pattern_item_idx);
                    if (pattern_item.value == .symbol and pattern_item.value.symbol.ptr == pool.getSymbol("...SYMBOL").ptr) {
                        std.debug.assert(i == pattern_list.items.len - 1); // rest pattern must be last
                        for (v.items[i+1..]) |rest_item_idx| {
                            const rest_item = lctx.get(item_idx);
                            if (rest_item.value != .symbol) {
                                return rest_item_idx;
                            }
                        }
                        break :outer;
                    } else if (pattern_item.value == .symbol and pattern_item.value.symbol.ptr == pool.getSymbol("...ANY").ptr) {
                        break :outer;
                    }
                    if (_findPatternMismatch(item_idx, lctx, pattern_item_idx, pctx, lvisited)) |mismatch|
                        return mismatch;
                }
                return null;
            },
        }
    }

    // TODO: add a special "wildcard" type to the Sexp.value union specifically for
    // pattern matching mode
    // TODO: make (a subset of) the parser work at comptime
    /// returns null if it matches, otherwise returns the sexp index at which it mismatched
    /// the pattern matching language looks like:
    /// ```scm
    /// (define (SYMBOL ...SYMBOL) ...ANY)
    /// ````
    /// where uppercase SYMBOL or e.g. FLOAT (unimplemented) requires that to be matched, and ...
    /// (which must occur at the last index of a list) will match 0 or more of that type
    ///
    /// Eventually it may be extended to support named captures in the pattern so it's easier to tell where
    /// a mismatch occurred
    pub fn findPatternMismatch(
        lctx: *const ModuleContext,
        index: u32,
        comptime pattern: []const u8,
    ) ?u32 {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var pat_diag = Parser.Diagnostic{ .source = pattern };
        var pattern_module = Parser.parse(std.heap.page_allocator, pattern, &pat_diag) catch {
            std.debug.print("Pattern match error: {}\n", .{pat_diag});
            //pat_diag.contextualize(std.io.getStdErr().writer());
            unreachable; 
        };
        defer pattern_module.deinit();
        var lvisited = std.AutoHashMap(u32, void).init(arena.allocator());
        defer lvisited.deinit();

        return _findPatternMismatch(index, lctx, 0, &pattern_module.module, &lvisited);
    }

    pub fn recursive_eq(self: *const Self, lctx: *ModuleContext, other: *const Self, rctx: *ModuleContext) bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var lvisited = std.AutoHashMap(*const Sexp, void).init(arena.allocator());
        defer lvisited.deinit();

        return _recursive_eq(self, lctx, other, rctx, &lvisited);
    }

    pub fn jsonValue(self: @This(), alloc: std.mem.Allocator) !json.Value {
        return switch (self.value) {
            .list => |v| _: {
                var result = json.Array.init(alloc);
                try result.ensureTotalCapacityPrecise(v.items.len);
                for (v.items) |item| {
                    (try result.addOne()).* = try item.jsonValue(alloc);
                }
                break :_ json.Value{ .array = result };
            },
            .module => |v| _: {
                var result = json.ObjectMap.init(alloc);
                // TODO: ensureTotalCapacityPrecise
                try result.put("module", try (Sexp{ .value = .{ .list = v } }).jsonValue(alloc));
                break :_ json.Value{ .object = result };
            },
            .float => |v| json.Value{ .float = v },
            .int => |v| json.Value{ .integer = v },
            .bool => |v| json.Value{ .bool = v },
            .void => .null,
            .ownedString => |v| json.Value{ .string = v },
            .borrowedString => |v| json.Value{ .string = v },
            .symbol => |v| _: {
                var result = json.ObjectMap.init(alloc);
                // TODO: ensureTotalCapacityPrecise
                try result.put("symbol", json.Value{ .string = v });
                break :_ json.Value{ .object = result };
            },
        };
    }

    /// struct to temporarily hold a module context to do things like formatting
    pub const WithModCtx = struct {
        module: *const ModuleContext,
        index: u32,

        pub fn format(self: *const @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var emitted_labels = std.AutoHashMap([*:0]const u8, void).init(arena.allocator());

            _ = try self.module.get(self.index)._write(self.module, writer, .{
                .emitted_labels = &emitted_labels,
            }, .{});
        }
    };

    fn withContext(module: *const ModuleContext, index: u32) WithModCtx {
        return WithModCtx{ .module = module, .index = index };
    }
};

test "free sexp" {
    const alloc = std.testing.allocator;
    const str = Sexp{ .value = .{ .ownedString = try alloc.alloc(u8, 10) } };
    defer str.deinit(alloc);
}

test "write sexp" {
    var list = std.ArrayListUnmanaged(u32).init(std.testing.allocator);
    try list.append(Sexp{ .value = .{ .symbol = "hello" } });
    try list.append(Sexp{ .value = .{ .borrowedString = "world\"" } });
    try list.append(Sexp{ .value = .{ .float = 0.5 } });
    try list.append(Sexp{ .value = .{ .float = 1.0 } });
    defer list.deinit();
    var root_sexp = Sexp{ .value = .{ .list = list } };

    var buff: [1024]u8 = undefined;
    var fixed_buffer_stream = std.io.fixedBufferStream(&buff);
    const writer = fixed_buffer_stream.writer();

    const bytes_written = try root_sexp.write(writer, .{});

    try testing.expectEqualStrings(
        \\(hello "world\""
        \\       0.5
        \\       1)
    , buff[0..bytes_written]);
}

test "findPatternMismatch" {
    inline for (&.{
        .{ .source = "(define (f x y) 2)", .pattern = "(define (SYMBOL ...SYMBOL) ...ANY)", .should_match = true },
        .{ .source = "(define (f x y) 2)", .pattern = "(define (SYMBOL SYMBOL SYMBOL) ...ANY)", .should_match = true },
        .{ .source = "(define (f) (g))", .pattern = "(define (SYMBOL ...SYMBOL) ...ANY)", .should_match = true },
        .{ .source = "(define (f))", .pattern = "(define (SYMBOL ...SYMBOL) ...ANY)", .should_match = true },
        .{ .source = "(define f)", .pattern = "(define (SYMBOL ...SYMBOL) ...ANY)", .should_match = false },
        .{ .source = "(typeof f 2)", .pattern = "(typeof SYMBOL ...ANY)", .should_match = true },
        .{ .source = "(typeof f)", .pattern = "(typeof SYMBOL ...ANY)", .should_match = true },
        .{ .source = "(define (bar x) (begin me))", .pattern = "(define (SYMBOL ...SYMBOL) (begin ...ANY))", .should_match = true },
    }) |info| {
        var diag = Parser.Diagnostic{ .source = info.source };
        defer if (diag.result != .none) {
            std.debug.print("source=\n{s}\n", .{info.source});
            std.debug.print("diag={}\n", .{diag});
        };
        var parsed = try Parser.parse(t.allocator, info.source, &diag);
        defer parsed.deinit();

        const maybe_mismatch = Sexp.findPatternMismatch(&parsed.module, 0, info.pattern);

        errdefer {
            if (maybe_mismatch) |mismatch| {
                std.debug.print("mismatch:\n{}\nin:\n{s}\n", .{Sexp.withContext(&parsed.module, mismatch), info.source});
            }
        }

        try t.expectEqual(info.should_match, maybe_mismatch == null);
    }

}

// TODO: move into the environment as known syms
pub const syms = struct {
    pub const meta = Sexp{ .value = .{ .symbol = "meta" } };
    pub const version = Sexp{ .value = .{ .symbol = "version" } };
    pub const import = Sexp{ .value = .{ .symbol = "import" } };
    pub const define = Sexp{ .value = .{ .symbol = "define" } };
    pub const typeof = Sexp{ .value = .{ .symbol = "typeof" } };
    pub const as = Sexp{ .value = .{ .symbol = "as" } };
    pub const begin = Sexp{ .value = .{ .symbol = "begin" } };
    pub const @"return" = Sexp{ .value = .{ .symbol = "return" } };
    // FIXME: is this really a symbol?
    pub const @"true" = Sexp{ .value = .{ .symbol = "#t" } };
    pub const @"false" = Sexp{ .value = .{ .symbol = "#f" } };
    pub const @"void" = Sexp{ .value = .{ .symbol = "#void" } };
    pub const quote = Sexp{ .value = .{ .symbol = "_quote" } }; // FIXME: currently json_quote is quote lol
    pub const hard_quote = Sexp{ .value = .{ .symbol = "hardquote" } };

    const builtin_nodes = @import("./nodes/builtin.zig").builtin_nodes;

    pub const @"+" = Sexp{ .value = .{ .symbol = builtin_nodes.@"+".name() } };
    pub const @"-" = Sexp{ .value = .{ .symbol = builtin_nodes.@"-".name() } };
    pub const @"*" = Sexp{ .value = .{ .symbol = builtin_nodes.@"*".name() } };
    pub const @"/" = Sexp{ .value = .{ .symbol = builtin_nodes.@"/".name() } };
    pub const @"==" = Sexp{ .value = .{ .symbol = builtin_nodes.@"==".name() } };
    pub const @"!=" = Sexp{ .value = .{ .symbol = builtin_nodes.@"!=".name() } };
    pub const @"<=" = Sexp{ .value = .{ .symbol = builtin_nodes.@"<=".name() } };
    pub const @"<" = Sexp{ .value = .{ .symbol = builtin_nodes.@"<".name() } };
    pub const @">" = Sexp{ .value = .{ .symbol = builtin_nodes.@">".name() } };
    pub const @">=" = Sexp{ .value = .{ .symbol = builtin_nodes.@">=".name() } };
    pub const not = Sexp{ .value = .{ .symbol = builtin_nodes.not.name() } };
    pub const @"and" = Sexp{ .value = .{ .symbol = builtin_nodes.@"and".name() } };
    pub const @"or" = Sexp{ .value = .{ .symbol = builtin_nodes.@"or".name() } };

    pub const @"if" = Sexp{ .value = .{ .symbol = builtin_nodes.@"if".name() } };
    pub const @"set!" = Sexp{ .value = .{ .symbol = builtin_nodes.@"set!".name() } };

    pub const min = Sexp{ .value = .{ .symbol = builtin_nodes.min.name() } };
    pub const max = Sexp{ .value = .{ .symbol = builtin_nodes.max.name() } };
    pub const string_indexof = Sexp{ .value = .{ .symbol = builtin_nodes.string_indexof.name() } };
    pub const string_length = Sexp{ .value = .{ .symbol = builtin_nodes.string_length.name() } };
    pub const string_equal = Sexp{ .value = .{ .symbol = builtin_nodes.string_equal.name() } };
    pub const string_join = Sexp{ .value = .{ .symbol = builtin_nodes.string_concat.name() } };

    // TODO: add a test that all builtin nodes are covered here...
    pub const make_vec3 = Sexp{ .value = .{ .symbol = builtin_nodes.make_vec3.name() } };
    pub const vec3_x = Sexp{ .value = .{ .symbol = builtin_nodes.vec3_x.name() } };
    pub const vec3_y = Sexp{ .value = .{ .symbol = builtin_nodes.vec3_y.name() } };
    pub const vec3_z = Sexp{ .value = .{ .symbol = builtin_nodes.vec3_z.name() } };

    pub const make_rgba = Sexp{ .value = .{ .symbol = builtin_nodes.make_rgba.name() } };
    pub const rgba_r = Sexp{ .value = .{ .symbol = builtin_nodes.rgba_r.name() } };
    pub const rgba_g = Sexp{ .value = .{ .symbol = builtin_nodes.rgba_g.name() } };
    pub const rgba_b = Sexp{ .value = .{ .symbol = builtin_nodes.rgba_b.name() } };
    pub const rgba_a = Sexp{ .value = .{ .symbol = builtin_nodes.rgba_a.name() } };

    pub const make_symbol = Sexp{ .value = .{ .symbol = builtin_nodes.make_symbol.name() } };
    pub const make_string = Sexp{ .value = .{ .symbol = builtin_nodes.make_string.name() } };

    pub const json_quote = Sexp{ .value = .{ .symbol = builtin_nodes.json_quote.name() } };
};

pub const primitive_type_syms = struct {
    pub const @"i32" = Sexp{ .value = .{ .symbol = "i32" } };
    pub const @"i64" = Sexp{ .value = .{ .symbol = "i64" } };
    pub const @"u32" = Sexp{ .value = .{ .symbol = "u32" } };
    pub const @"u64" = Sexp{ .value = .{ .symbol = "u64" } };
    pub const @"f32" = Sexp{ .value = .{ .symbol = "f32" } };
    pub const @"f64" = Sexp{ .value = .{ .symbol = "f64" } };
};

pub fn writeWatMemoryString(data: []const u8, writer: anytype) !void {
    for (data) |char| {
        switch (char) {
            '\\' => {
                try writer.writeAll("\\\\");
            },
            // printable ascii not including '\\' or '"'
            ' '...'"' - 1, '"' + 1...'\\' - 1, '\\' + 1...127 => {
                try writer.writeByte(char);
            },
            // FIXME: use ascii bit magic/table here, I'm too lazy and time pressed
            else => {
                try writer.writeByte('\\');
                try std.fmt.formatInt(char, 16, .lower, .{ .width = 2, .fill = '0' }, writer);
            },
        }
    }
}
