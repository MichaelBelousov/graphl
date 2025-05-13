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
const Loc = @import("./loc.zig").Loc;

// FIXME: don't include in non-debug builds

fn _print_sexp(mod_ctx: *const ModuleContext, sexp_idx: u32) callconv(.C) void {
    std.debug.print("{}\n", .{Sexp.withContext(mod_ctx, sexp_idx)});
}

comptime {
    if (builtin.target.cpu.arch != .wasm32 and builtin.mode == .Debug) {
        @export(&_print_sexp, .{ .name = "_print_sexp", .linkage = .strong });
    }
}

// TODO: add an init function that initializes the root for you
pub const ModuleContext = struct {
    // TODO: rename from arena, to like "slots" or something, as zig uses arena already
    arena: std.ArrayListUnmanaged(Sexp) = .{},
    source: ?[]const u8 = null,
    // NOTE: do not use an arena for this since 'arena' may grow often!
    _alloc: std.mem.Allocator,

    pub inline fn alloc(self: *@This()) std.mem.Allocator {
        return self._alloc;
    }

    pub inline fn add(self: *@This(), sexp: Sexp) !u32 {
        try self.arena.append(self.alloc(), sexp);
        return @intCast(self.arena.items.len - 1);
    }

    pub inline fn addGet(self: *@This(), sexp: Sexp) !*Sexp {
        return &self.arena.items[try self.add(sexp)];
    }

    pub inline fn addToRoot(self: *@This(), sexp: Sexp) !u32 {
        const added = try self.add(sexp);
        try self.getRoot().value.module.append(self.alloc(), added);
        return added;
    }

    pub inline fn get(self: *const @This(), index: u32) *Sexp {
        return &self.arena.items[index];
    }

    pub inline fn getRoot(self: *const @This()) *Sexp {
        return self.get(0);
    }

    /// useful because an inline add can invalidate the array list
    pub inline fn addAndAppendToList(self: *@This(), index: u32, sexp: Sexp) !u32 {
        const added_idx = try self.add(sexp);
        try self.get(index).body().append(self.alloc(), added_idx);
        return added_idx;
    }

    pub fn init(a: std.mem.Allocator) !@This() {
        return initCapacity(a, 1);
    }

    pub fn initCapacity(a: std.mem.Allocator, capacity: usize) !@This() {
        var arena = try std.ArrayListUnmanaged(Sexp).initCapacity(a, capacity);
        arena.appendAssumeCapacity(try .emptyModuleCapacity(a, capacity - 1));

        return @This(){
            .arena = arena,
            ._alloc = a,
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.arena.items) |*sexp| {
            sexp.deinit(self.alloc());
        }
        self.arena.deinit(self.alloc());
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
    /// optional source location, when parsed from a source file, for debug info in the compiler or diagnostics
    loc: ?Loc = null,
    /// label if there is one on this sexp
    label: ?[:0]const u8 = null,
    value: union(enum) {
        // FIXME: remove module type since it mostly just creates useless branching that
        // ModuleContext can handle special casing of
        /// holds indices into the arena
        module: std.ArrayListUnmanaged(u32),
        // NOTE: consider separating empty list and symbol-started list into variants
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
        /// looks like: '>!target'
        jump: struct {
            // FIXME: remove, can just read the label from the target
            name: [:0]const u8,
            target: u32,
        },
        // /// looks like: '#!target.0'
        valref: ValRef,
        // TODO: quote/quasiquote, etc
    },

    pub const ValRef = struct {
        target: u32,
    };

    const Self = @This();

    fn deinit(
        self: *@This(),
        /// probably should be the ModuleContext.alloc()
        alloc: std.mem.Allocator,
    ) void {
        switch (self.value) {
            // FIXME: figure out ownership for this... currently most common case
            // is owned by an arena allocator from the SexpParser.ParseResult
            .ownedString => {},
            .list, .module => |*v| v.deinit(alloc),
            .void, .int, .float, .bool, .borrowedString, .symbol, .jump, .valref, .deadcode => {},
        }
    }

    // FIXME: deprecate
    pub fn emptyList() Sexp {
        return empty_list;
    }

    pub const empty_list = Sexp{ .value = .{ .list = .empty } };

    // FIXME: why not force use the module context's arena allocator?
    pub fn emptyListCapacity(alloc: std.mem.Allocator, capacity: usize) !Sexp {
        return Sexp{ .value = .{ .list = try std.ArrayListUnmanaged(u32).initCapacity(alloc, capacity) } };
    }

    pub fn symbol(sym: []const u8) Sexp {
        return Sexp{ .value = .{ .symbol = pool.getSymbol(sym) } };
    }

    pub fn valref(in_valref: ValRef) Sexp {
        return Sexp{ .value = .{ .valref = in_valref } };
    }

    pub fn jump(name: []const u8, target: u32) Sexp {
        return Sexp{ .value = .{ .jump = .{
            .name = pool.getSymbol(name),
            .target = target,
        } } };
    }

    pub fn int(value: i64) Sexp {
        return Sexp{ .value = .{ .int = value } };
    }

    pub fn float(value: f64) Sexp {
        return Sexp{ .value = .{ .float = value } };
    }

    // FIXME: deprecate
    pub fn emptyModule() Sexp {
        return empty_module;
    }

    pub const empty_module = Sexp{ .value = .{ .module = .empty } };

    pub fn emptyModuleCapacity(alloc: std.mem.Allocator, capacity: usize) !Sexp {
        return Sexp{ .value = .{ .module = try std.ArrayListUnmanaged(u32).initCapacity(alloc, capacity) } };
    }

    pub fn body(self: *Self) *std.ArrayListUnmanaged(u32) {
        return switch (self.value) {
            .list, .module => |*v| v,
            else => @panic("can only call 'body' on modules and lists"),
        };
    }

    pub fn getWithModule(self: *const Self, index: usize, mod_ctx: *const ModuleContext) *Sexp {
        return switch (self.value) {
            .list, .module => |*v| mod_ctx.get(v.items[index]),
            else => @panic("can only call 'getWithModule' on modules and lists"),
        };
    }

    pub fn toOwnedSlice(self: *Self) ![]Sexp {
        return switch (self.value) {
            .list, .module => |*v| v.toOwnedSlice(),
            else => @panic("can only call toOwnedSlice on modules and lists"),
        };
    }

    const WriteState = struct {
        /// number of indents we are in
        depth: usize = 0,
        emitted_labels: *std.AutoHashMap([*:0]const u8, void),
    };

    fn writeModule(mod_ctx: *const ModuleContext, form: *const std.ArrayListUnmanaged(u32), writer: anytype, state: WriteState, comptime opts: WriteOptions) @TypeOf(writer).Error!WriteState {
        for (form.items, 0..) |item_idx, i| {
            if (i != 0) _ = try writer.write(if (opts.do_indent) "\n" else " ");
            const item = &mod_ctx.arena.items[item_idx];
            if (opts.do_indent)
                try writer.writeByteNTimes(' ', state.depth);
            _ = try item._write(mod_ctx, writer, .{ .depth = state.depth, .emitted_labels = state.emitted_labels }, opts);
        }

        return .{ .depth = 0, .emitted_labels = state.emitted_labels };
    }

    fn writeList(mod_ctx: *const ModuleContext, form: *const std.ArrayListUnmanaged(u32), writer: anytype, state: WriteState, comptime opts: WriteOptions) @TypeOf(writer).Error!WriteState {
        var depth: usize = 0;

        depth += try writer.write("(");

        if (form.items.len >= 1) {
            depth += (try mod_ctx.arena.items[form.items[0]]._write(
                mod_ctx,
                writer,
                .{ .depth = state.depth + depth, .emitted_labels = state.emitted_labels },
                opts,
            )).depth;
        }

        if (form.items.len >= 2) {
            depth += try writer.write(" ");

            _ = try mod_ctx.arena.items[form.items[1]]._write(mod_ctx, writer, .{ .depth = state.depth + depth, .emitted_labels = state.emitted_labels }, opts);

            for (form.items[2..]) |item_idx| {
                const item = &mod_ctx.arena.items[item_idx];
                if (opts.do_indent) {
                    _ = try writer.write("\n");
                    try writer.writeByteNTimes(' ', state.depth + depth);
                } else {
                    _ = try writer.write(" ");
                }
                _ = try item._write(mod_ctx, writer, .{ .depth = state.depth + depth, .emitted_labels = state.emitted_labels }, opts);
            }
        }

        _ = try writer.write(")");

        return .{
            .depth = depth,
            .emitted_labels = state.emitted_labels,
        };
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

    const WriteOptions = struct {
        do_indent: bool = true,
        string_literal_dialect: enum {
            json,
            wat,
            // HACK: backslashes can't be escaped cuz this sucks. Temporary to make encoding
            // WAT easier (FIXME: can be removed now that I don't write my own WAT)
            /// only escapes quotes, not even backslashes
            simple,
        } = .simple,
    };

    fn _write(self: *const Self, mod_ctx: *const ModuleContext, writer: anytype, state: WriteState, comptime opts: WriteOptions) @TypeOf(writer).Error!WriteState {
        if (self.label) |label| {
            if (state.emitted_labels.contains(label.ptr)) {
                std.debug.panic("sexp cycles not allowed", .{});
                // FIXME: weird old code from back when sexp cycles were allowed
                _ = try writer.write(">!");
                _ = try writer.write(label);
                return .{
                    .depth = ">!".len + label.len,
                    .emitted_labels = state.emitted_labels,
                };
            } else {
                // FIXME: handle OOM better
                // FIXME: this is not correct when do_indent is false!
                state.emitted_labels.put(label.ptr, {}) catch unreachable;
                if (opts.do_indent) {
                    _ = try writer.write("\n");
                    _ = try writer.writeByteNTimes(' ', state.depth);
                }
                _ = try writer.write("<!");
                _ = try writer.write(label);
                if (opts.do_indent) {
                    _ = try writer.write("\n");
                    _ = try writer.writeByteNTimes(' ', state.depth);
                } else {
                    _ = try writer.write(" ");
                }
            }
        }

        // TODO: calculate stack space requirements?
        const write_depth: usize = switch (self.value) {
            .module => |v| (try writeModule(mod_ctx, &v, writer, state, opts)).depth,
            .list => |v| (try writeList(mod_ctx, &v, writer, state, opts)).depth,
            inline .float, .int => |v| _: {
                var counting_writer = std.io.countingWriter(writer);
                try counting_writer.writer().print("{d}", .{v});
                break :_ @as(usize, @intCast(counting_writer.bytes_written));
            },
            .bool => |v| _: {
                _ = try writer.write(if (v) syms.true.value.symbol else syms.false.value.symbol);
                std.debug.assert(syms.true.value.symbol.len == syms.false.value.symbol.len);
                break :_ syms.true.value.symbol.len;
            },
            .void => _: {
                _ = try writer.write(syms.void.value.symbol);
                break :_ syms.void.value.symbol.len;
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
                break :_ @as(usize, @intCast(cw.bytes_written + 2));
            },
            .symbol => |v| _: {
                try writer.print("{s}", .{v});
                break :_ v.len;
            },
            .jump => |v| _: {
                try writer.print(">!{s}", .{v.name});
                break :_ v.name.len;
            },
            .valref => |v| _: {
                const target = mod_ctx.get(v.target);
                var cw = std.io.countingWriter(writer);
                try cw.writer().print("#!{s}", .{target.label orelse unreachable});
                break :_ @as(usize, @intCast(cw.bytes_written));
            },
        };

        return WriteState{
            .depth = write_depth,
            .emitted_labels = state.emitted_labels,
        };
    }

    pub fn write(self: *const Self, mod_ctx: *const ModuleContext, writer: anytype, comptime options: WriteOptions) !usize {
        var counting_writer = std.io.countingWriter(writer);

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var emitted_labels = std.AutoHashMap([*:0]const u8, void).init(arena.allocator());

        _ = try self._write(mod_ctx, counting_writer.writer(), .{
            .emitted_labels = &emitted_labels,
        }, options);
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
            .symbol => |v| return std.meta.eql(v, other.value.symbol),
            .jump => |v| {
                const ltarget_label = lctx.get(v.target).label;
                const rtarget_label = rctx.get(other.value.jump.target).label;
                return std.mem.eql(u8, ltarget_label.?, rtarget_label.?);
            },
            .valref => |v| {
                const ltarget_label = lctx.get(v.target).label;
                const rtarget_label = rctx.get(other.value.valref.target).label;
                return std.mem.eql(u8, ltarget_label.?, rtarget_label.?);
            },
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
        // FIXME: make sure this is correct, I haven't tested this with labels
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
            .symbol => |v| return if (std.meta.eql(v, pattern.value.symbol)) null else self_index,
            .jump => @panic("unsupported pattern type"),
            .valref => @panic("unsupported pattern type"),
            inline .module, .list => |v, sexp_type| {
                const pattern_list = @field(pattern.value, @tagName(sexp_type));
                var i: usize = 0;
                outer: while (i < v.items.len and i < pattern_list.items.len) : (i += 1) {
                    const item_idx = v.items[i];
                    const pattern_item_idx = pattern_list.items[i];
                    const pattern_item = pctx.get(pattern_item_idx);
                    if (pattern_item.value == .symbol and pattern_item.value.symbol.ptr == pool.getSymbol("...SYMBOL").ptr) {
                        std.debug.assert(i == pattern_list.items.len - 1); // rest pattern must be last
                        for (v.items[i + 1 ..]) |rest_item_idx| {
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

        // for now, only allow pattern matching 1 element. Technically we could just loop through all the root
        // elements and compare them
        std.debug.assert(pattern_module.module.getRoot().value.module.items.len == 1);

        return _findPatternMismatch(
            index,
            lctx,
            // compare the first element of the module, not the entire module
            1,
            &pattern_module.module,
            &lvisited,
        );
    }

    pub fn recursive_eq(self: *const Self, lctx: *ModuleContext, other: *const Self, rctx: *ModuleContext) bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var lvisited = std.AutoHashMap(*const Sexp, void).init(arena.allocator());
        defer lvisited.deinit();

        return _recursive_eq(self, lctx, other, rctx, &lvisited);
    }

    pub fn jsonValue(self: @This(), mod: *const ModuleContext, alloc: std.mem.Allocator) !json.Value {
        return switch (self.value) {
            .list => |v| _: {
                var result = json.Array.init(alloc);
                try result.ensureTotalCapacityPrecise(v.items.len);
                for (v.items) |item_idx| {
                    const item = mod.get(item_idx);
                    (try result.addOne()).* = try item.jsonValue(mod, alloc);
                }
                break :_ json.Value{ .array = result };
            },
            .module => |v| _: {
                var result = json.ObjectMap.init(alloc);
                // TODO: ensureTotalCapacityPrecise
                try result.put("module", try (Sexp{ .value = .{ .list = v } }).jsonValue(mod, alloc));
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
            .jump => |v| _: {
                var result = json.ObjectMap.init(alloc);
                try result.put("jump", json.Value{ .string = v.name });
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

    // TODO: rename
    pub fn withContext(module: *const ModuleContext, index: u32) WithModCtx {
        return WithModCtx{ .module = module, .index = index };
    }

    pub const PrintOneLine = struct {
        module: *const ModuleContext,
        index: u32,

        pub fn format(self: *const @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var emitted_labels = std.AutoHashMap([*:0]const u8, void).init(arena.allocator());

            _ = try self.module.get(self.index)._write(
                self.module,
                writer,
                .{ .emitted_labels = &emitted_labels },
                .{ .do_indent = false },
            );
        }
    };

    pub fn printOneLine(module: *const ModuleContext, index: u32) PrintOneLine {
        return PrintOneLine{ .module = module, .index = index };
    }
};

test "write sexp" {
    var mod = try ModuleContext.initCapacity(t.allocator, 5);
    defer mod.deinit();

    const list = try mod.addGet(try .emptyListCapacity(mod.alloc(), 4));
    list.value.list.appendAssumeCapacity(try mod.add(Sexp{ .value = .{ .borrowedString = "world\"" } }));
    list.value.list.appendAssumeCapacity(try mod.add(Sexp{ .value = .{ .float = 0.5 } }));
    list.value.list.appendAssumeCapacity(try mod.add(Sexp{ .value = .{ .float = 1.0 } }));

    var buff: [1024]u8 = undefined;
    var fixed_buffer_stream = std.io.fixedBufferStream(&buff);
    const writer = fixed_buffer_stream.writer();

    const bytes_written = try mod.getRoot().write(&mod, writer, .{});

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
        .{ .source = "(meta version 2)", .pattern = "(meta version 1)", .should_match = false },
        .{ .source = "(meta version 1)", .pattern = "(meta version 1)", .should_match = true },
        .{ .source = "(typeof (++ i32) i32)", .pattern = "(typeof (SYMBOL ...SYMBOL) ...ANY)", .should_match = true },
        .{
            .source =
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
            ,
            .pattern = "(define (SYMBOL ...SYMBOL) ...ANY)",
            .should_match = true,
        },
    }) |info| {
        var diag = Parser.Diagnostic{ .source = info.source };
        defer if (diag.result != .none) {
            std.debug.print("source=\n{s}\n", .{info.source});
            std.debug.print("diag={}\n", .{diag});
        };
        var parsed = try Parser.parse(t.allocator, info.source, &diag);
        defer parsed.deinit();

        const maybe_mismatch = Sexp.findPatternMismatch(&parsed.module, 1, info.pattern);

        errdefer {
            if (maybe_mismatch) |mismatch| {
                std.debug.print("mismatch:\n{}\nin:\n{s}\n", .{ Sexp.withContext(&parsed.module, mismatch), info.source });
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
    // FIXME: replace with true and false literals, not this weird #t thing
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
