// TODO: give better name... C slice?
pub const Slice = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn fromZig(slice: []const u8) @This() {
        return @This(){ .ptr = slice.ptr, .len = slice.len };
    }

    pub fn toZig(self: @This()) []const u8 {
        return self.ptr[0..self.len];
    }
};
