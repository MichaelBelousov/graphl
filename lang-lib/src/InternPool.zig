const std = @import("std");

pub const Interned = struct {};

pub const InternPool = struct {
    const Hash = usize;
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

// TODO: only one pool can exist per process?
pub var pool: InternPool = .{};

test "smoke" {
    const hello1 = "hello";
    const hello2 = try std.testing.allocator.dupe(u8, hello1);
    defer std.testing.allocator.free(hello2);

    try std.testing.expect(hello1.ptr != hello2.ptr);

    const hello3 = pool.getSymbol(hello1);
    const hello4 = pool.getSymbol(hello2);

    try std.testing.expect(hello3.ptr == hello4.ptr);
}
