const std = @import("std");

// nothin like premature optimization, vroom vroom

/// A specialized bitset that only allows access to bits after a certain index,
/// preserving the indexes of a larger bitset, but effectively only storing enough
/// space for the necessary bits, and allowing merging with larget bit sets
pub const RearBitSubSet = struct {
    /// will be rounded down to a multiple of @bitSizeOf(usize)
    index_offset: usize = 0,
    /// note that all indices must be offset by the index_offset to get the corresponding node
    /// in GraphBuilder.nodes
    _set: std.DynamicBitSetUnmanaged,

    const MaskInt = std.DynamicBitSetUnmanaged.MaskInt;

    pub fn initEmpty(alloc: std.mem.Allocator, wanted_index: usize, total_node_count: usize) !@This() {
        // round to nearest multiple of @bitSizeOf(usize)
        const rounded_offset = (wanted_index / @bitSizeOf(usize)) * @bitSizeOf(usize);
        const required_node_count = total_node_count - rounded_offset;
        return @This(){
            .index_offset = rounded_offset,
            ._set = try std.DynamicBitSetUnmanaged.initEmpty(alloc, required_node_count),
        };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self._set.deinit(alloc);
    }

    /// 'other' must be a subset (its index_offset must be >= to ours)
    pub fn setUnion(self: *@This(), other: @This()) void {
        std.debug.assert(other.index_offset >= self.index_offset);
        const rel_offset = other.index_offset - self.index_offset;
        const rel_mask_offset = rel_offset / @bitSizeOf(MaskInt);
        std.debug.assert(self._set.bit_length == other._set.bit_length + rel_offset);

        // adapted from from DynamicBitSetUnmanaged.setUnion
        const num_masks = (self._set.bit_length + (@bitSizeOf(MaskInt) - 1)) / @bitSizeOf(MaskInt);
        for (self._set.masks[rel_mask_offset..num_masks], 0..) |*mask, i| {
            mask.* |= other._set.masks[i];
        }
    }

    pub fn set(self: *@This(), index: usize) void {
        return self._set.set(index - self.index_offset);
    }

    pub fn count(self: @This()) usize {
        return self._set.count();
    }

    pub fn isSet(self: @This(), index: usize) bool {
        return self._set.isSet(index - self.index_offset);
    }
};

test "setUnion" {
    var superset = try RearBitSubSet.initEmpty(std.testing.allocator, 2, 170);
    defer superset.deinit(std.testing.allocator);
    superset.set(50);
    superset.set(150);
    var subset = try RearBitSubSet.initEmpty(std.testing.allocator, 129, 170);
    defer subset.deinit(std.testing.allocator);
    subset.set(129);
    subset.set(169);

    superset.setUnion(subset);

    try std.testing.expectEqual(superset.count(), 4);
    try std.testing.expect(superset.isSet(50));
    try std.testing.expect(superset.isSet(129));
    try std.testing.expect(superset.isSet(150));
    try std.testing.expect(superset.isSet(169));
}
