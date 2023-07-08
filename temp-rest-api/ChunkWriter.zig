const std = @import("std");
const page_size = std.mem.page_size;

const Page = [page_size]u8;

/// TODO: consider renaming... PagedWriter?
const ChunkWriter = struct {
    page_size: usize = page_size,
    pages: std.SegmentedList(Page, 0),
    writeable_page: []u8,
    alloc: std.mem.Allocator,

    const Self = @This();

    /// return a linear memory slice of all the written chunks, allocated by the passed in allocator
    /// you must free it yourself
    pub fn concat(self: Self, alloc: std.mem.Allocator) ![]u8 {
        var pages_iter = self.pages.constIterator(0); 
        const last_page_written_num = page_size - self.writeable_page.len;
        const buff_size = (self.pages.count() - 1) * page_size + last_page_written_num;
        const buff = try alloc.alloc(u8, buff_size);
        var cursor: usize = 0;
        
        var index: usize = 0;
        while (pages_iter.next()) |page| {
            const is_last = index == self.pages.count() - 1;
            const copy_size = if (is_last) last_page_written_num else page_size;
            std.mem.copy(u8, buff[cursor..cursor + copy_size], page[0..copy_size]);
            index += 1;
            cursor += copy_size;
        }

        return buff;
    }

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

    fn writeFn(self: *Self, bytes: []const u8) WriteError!usize {
        var remaining_bytes = bytes;

        while (remaining_bytes.len > 0) {
            if (self.writeable_page.len == 0) {
                self.writeable_page = (try self.pages.addOne(self.alloc))[0..page_size];
            }
            const next_end = std.math.min(self.writeable_page.len, remaining_bytes.len);
            const bytes_for_current_page = remaining_bytes[0..next_end];
            std.mem.copy(u8, self.writeable_page, bytes_for_current_page);
            self.writeable_page = self.writeable_page[bytes_for_current_page.len..self.writeable_page.len];
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

    const concated = try chunk_writer.concat(std.testing.allocator);
    defer std.testing.allocator.free(concated);
    try std.testing.expectEqualSlices(u8, data, concated);

    _ = try writer.write(data);
}

