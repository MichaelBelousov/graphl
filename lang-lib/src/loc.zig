const std = @import("std");

pub const Loc = struct {
    /// url or file path or "unknown"
    source_ref: []const u8 = "unknown",
    /// 1-indexed
    line: usize = 1,
    /// 1-indexed
    col: usize = 1,
    index: usize = 0,

    fn find_backwards(haystack: []const u8, needle: u8, start: ?usize) ?usize {
        var i = start orelse std.mem.len(haystack) - 1;
        while (i > 0) : (i -= 1) {
            if (haystack[i] == needle) return i;
        }
        return null;
    }

    pub fn containing_line(self: @This(), source: []const u8) ![]const u8 {
        const line_start =
            if (self.index > 0)
                if (find_backwards(source, '\n', self.index - 1)) |i|
                    i + 1
                else 0
            else 0;
        const line_end =  std.mem.sliceTo(source[self.index..], '\n').len + self.index;
        return source[line_start..line_end];
    }

    pub fn increment(self: *@This(), c: u8) void {
        switch (c) {
            '\n' => {
                self.line += 1;
                self.col = 1;
                self.index += 1;
            },
            else => {
                self.index += 1;
                self.col += 1;
            }
        }
    }

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try writer.print("{s}:{}:{}", .{self.source_ref, self.line, self.col});
    }
};

test "containing_line" {
    const src =
        \\hello
        \\I am a line
        \\
        \\the end
    ;
    try std.testing.expectEqualStrings(
        "I am a line",
        try (Loc{ .col = 4, .line = 2, .index=10 }).containing_line(src)
    );
    try std.testing.expectEqualStrings(
        "I am a line",
        try (Loc{ .col = 1, .line = 2, .index=6 }).containing_line(src)
    );
    try std.testing.expectEqualStrings(
        "hello",
        try (Loc{ .col = 6, .line = 1, .index=5 }).containing_line(src)
    );
    try std.testing.expectEqualStrings(
        "",
        try (Loc{ .col = 1, .line = 3, .index=18 }).containing_line(src)
    );
}

pub const C_Loc = extern struct {
    source_ref: [*:0]const u8,
    line: usize = 1,
    col: usize = 1,
    index: usize = 0,
};

