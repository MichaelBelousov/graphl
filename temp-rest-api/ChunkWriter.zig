const std = @import("std");
const page_size = std.mem.page_size;

const Page = [page_size]u8;

const ChunkWriter = struct {
    pages: std.SegmentedList(Page, 0),
    writeable_page: []u8,
    alloc: std.mem.Allocator,

    const Self = @This();

    // pub fn concat(self: Self, alloc: std.mem.Allocator) void {
    //     std.mem.concat();
    // }

    fn init(alloc: std.mem.Allocator) !Self {
        var pages = std.SegmentedList(Page, 0){};
        var first_page = try pages.addOne(alloc);
        return Self {
            .alloc = alloc,
            .pages = pages,
            .writeable_page = first_page,
        };
    }

    fn deinit(self: *Self) void {
        self.pages.deinit(self.alloc);
    }

    const WriteError = error {} || std.mem.Allocator.Error;

    fn writeFn(ctx: *ChunkWriter, bytes: []const u8) WriteError!usize {
        var remaining_bytes = bytes;

        while (remaining_bytes.len > 0) {
            if (ctx.writeable_page.len == 0) {
                ctx.writeable_page = (try ctx.pages.addOne(ctx.alloc))[0..page_size];
            }
            const next_end = std.math.min(ctx.writeable_page.len, remaining_bytes.len);
            const bytes_for_current_page = remaining_bytes[0..next_end];
            std.mem.copy(u8, ctx.writeable_page, bytes_for_current_page);
            ctx.writeable_page = ctx.writeable_page[bytes_for_current_page.len..ctx.writeable_page.len];
            remaining_bytes = remaining_bytes[bytes_for_current_page.len..];
        }
        return bytes.len;
    }

    pub fn writer(self: *Self) std.io.Writer(*ChunkWriter, WriteError, writeFn) {
        return std.io.Writer(*ChunkWriter, WriteError, writeFn){
            .context = self,
        };
    }
};

test "write some pages" {
    const data = try std.testing.allocator.alloc(u8, std.mem.page_size * 3 + std.mem.page_size / 2 + 11);
    defer std.testing.allocator.free(data);
    std.mem.set(u8, data, 'a');

    var chunk_writer = try ChunkWriter.init(std.testing.allocator);
    defer chunk_writer.deinit();
    const writer = chunk_writer.writer();

    _ = try writer.write(data);
    _ = try writer.write(data);
}

