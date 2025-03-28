const std = @import("std");

pub const Interned = struct {};

pub const InternPool = struct {
    const Hash = u64;
    const Context = struct {
        pub fn hash(self: @This(), s: Hash) u64 {
            _ = self;
            return s;
        }
        pub fn eql(self: @This(), a: Hash, b: Hash) bool {
            _ = self;
            return a == b;
        }
    };

    _arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    _map: std.HashMapUnmanaged(
        Hash,
        [:0]const u8,
        Context,
        std.hash_map.default_max_load_percentage,
    ) = .{},

    // MAYBE: return a "Symbol" instead of a [:0]const u8, would make the equality
    // checks harder to screw up
    pub const Sym = enum(u64) {
        _,

        /// pointer to string data prefaced by usize length
        pub const Entry = opaque {
            pub fn len(self: *const @This()) usize {
                const len_ptr: *usize = @ptrCast(self);
                return len_ptr.*;
            }

            pub fn ptr(self: *const @This()) [*]const u8 {
                return @ptrCast(self + @sizeOf(usize));
            }
        };

        fn string(self: @This()) [:0]const u8 {
            const entry: Entry = @ptrFromInt(self);
            return entry.ptr()[0..entry.len()];
        }
    };

    pub fn getSymbol(self: *@This(), symbol: []const u8) [:0]const u8 {
        const hash = (std.hash_map.StringContext{}).hash(symbol);
        const res = self._map.getOrPut(self._arena.allocator(), hash) catch |e| std.debug.panic("OOM: {}", .{e});
        if (!res.found_existing) {
            res.value_ptr.* = self._arena.allocator().dupeZ(u8, symbol) catch |e| std.debug.panic("OOM: {}", .{e});
        }
        return res.value_ptr.*;
    }

    pub fn deinit(self: *@This()) void {
        //self._map.deinit(self._alloc);
        self._arena.deinit();
    }
};

pub fn SymMapUnmanaged(comptime V: type) type {
    const SymMapContext = struct {
        pub fn hash(self: @This(), s: [:0]const u8) u64 {
            _ = self;
            return @intFromPtr(s.ptr);
        }
        pub fn eql(self: @This(), a: [:0]const u8, b: [:0]const u8) bool {
            _ = self;
            return a.ptr == b.ptr;
        }
    };

    return std.HashMapUnmanaged(
        [:0]const u8,
        V,
        SymMapContext,
        std.hash_map.default_max_load_percentage,
    );
}

fn addSourceSymbol(self: *InternPool, symbol: [:0]const u8) void {
    const hash = (std.hash_map.StringContext{}).hash(symbol);
    const res = self._map.getOrPut(self._arena.allocator(), hash) catch |e| std.debug.panic("OOM: {}", .{e});
    res.value_ptr.* = symbol;
    if (res.found_existing) {
        std.debug.panic("source symbol already exists for: '{s}'\n", .{symbol});
    }
}

// TODO: only one pool can exist per process?
pub var pool: InternPool = .{};

fn constructor() callconv(.C) void {
    const syms = @import("./sexp.zig").syms;
    const sym_decls = @typeInfo(syms).@"struct".decls;
    inline for (sym_decls) |sym_decl| {
        const sym = @field(syms, sym_decl.name);
        _ = addSourceSymbol(&pool, sym.value.symbol);
    }
}

// FIXME: does this work in wasm?
export const _pool_init_array: [1]*const fn () callconv(.C) void linksection(".init_array") = .{&constructor};

test "smoke" {
    const hello1 = "hello";
    const hello2 = try std.testing.allocator.dupe(u8, hello1);
    defer std.testing.allocator.free(hello2);

    try std.testing.expect(hello1.ptr != hello2.ptr);

    const hello3 = pool.getSymbol(hello1);
    const hello4 = pool.getSymbol(hello2);

    try std.testing.expect(hello3.ptr == hello4.ptr);
}
