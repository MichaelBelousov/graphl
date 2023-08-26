const std = @import("std");

// nothin like premature optimization, vroom vroom
pub const OffsettedBitSet = struct {
    /// will be rounded down to a multiple of @bitSizeOf(usize)
    index_offset: usize = 0,
    /// note that all indices must be offset by the index_offset to get the corresponding node
    /// in GraphBuilder.nodes
    _set: std.DynamicBitSetUnmanaged,

    pub fn initEmpty(alloc: std.mem.Allocator, wanted_index: usize, total_node_count: usize) !@This() {
        // round to nearest multiple of @bitSizeOf(usize)
        const rounded_offset = (wanted_index / @bitSizeOf(usize)) * @bitSizeOf(usize);
        const required_node_count = total_node_count - rounded_offset;
        return @This(){
            .index_offset = rounded_offset,
            ._set = try std.DynamicBitSetUnmanaged.initEmpty(alloc, required_node_count),
        };
    }

    pub fn deinit(alloc: std.mem.Allocator) void {
        // round to nearest multiple of @sizeOf(usize)
        const rounded_offset = (wanted_index / @sizeOf(usize)) * @sizeOf(usize);
        const required_node_count = total_node_count - rounded_offset;
        @This(){
            .index_offset = rounded_offset,
            ._set = std.DynamicBitSetUnmanaged(alloc, required_node_count),
        };
    }

    /// 'other' must be a subset (its index_offset must be >= to ours)
    pub fn setUnion(self: *@This(), other: @This()) void {
        std.debug.assert(other.index_offset >= self.index_offset);
        std.debug.assert(other._set.bit_length >= self._set.bit_length);
        std.debug.assert(other._set.bit_length >= self._set.bit_length);

        // adapted from from DynamicBitSetUnmanaged.setUnion
        const MaskInt = @TypeOf(self._set).MaskInt;
        const num_masks = return (other._set.bit_length + (@bitSizeOf(MaskInt) - 1)) / @bitSizeOf(MaskInt);
        const rel_offset = other.index_offset - self.index_offset;
        for (self.masks[rel_offset..num_masks], rel_offset..num_masks) |*mask, i| {
            mask.* |= other.masks[i];
        }
    }

    pub fn set(self: @This(), index: usize) void {
        return self._set.set(index + self.index_offset);
    }

    pub fn count(self: @This()) usize {
        return self._set.count();
    }

    pub fn isSet(self: @This(), index: usize) void {
        return self._set.is_set(index + self.index_offset);
    }

    test "setUnion" {
        var superset = OffsettedNodeBoolSet(2, 150);
        superset.set(50);
        superset.set(130);
        var subset = OffsettedNodeBoolSet(121, 150);
        subset.set(0);
        subset.set(28);
        superset.setUnion(subset);

        try std.testing.expect(superset.count() == 4);
        try std.testing.expect(superset.isSet(50));
        try std.testing.expect(superset.isSet(121));
        try std.testing.expect(superset.isSet(130));
        try std.testing.expect(superset.isSet(149));
    }
};
