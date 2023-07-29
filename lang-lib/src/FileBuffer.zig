const builtin = @import("builtin");
const std = @import("std");
// not used and therefore ignored off posix
const mman = @cImport({ @cInclude("sys/mman.h"); });

buffer: []const u8,

const Self = @This();

pub fn fromDirAndPath(alloc: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !Self {
    const file = try dir.openFile(path, .{});
    defer file.close();
    return fromFile(alloc, file);
}

pub fn fromAbsPath(alloc: std.mem.Allocator, path: []const u8) !Self {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return fromFile(alloc, file);
}

pub fn fromFile(alloc: std.mem.Allocator, file: std.fs.File) !Self {
    const file_len = (try file.stat()).size;

    switch (builtin.os.tag) {
        .windows => {
            const buffer = try alloc.alloc(u8, @intCast(file_len));
            _ = try file.readAll(buffer);
            return Self{ .buffer = buffer };
        },
        // BUG: readAll for some reason blocks in wasmtime on non-empty files
        .wasi => {
            const buffer = try alloc.alloc(u8, @intCast(file_len));
            var total_bytes_read: usize = 0;
            while (file.read(buffer[total_bytes_read..])) |bytes_read| {
                if (bytes_read == 0) break;
                total_bytes_read += bytes_read;
            } else |err| return err;
            return Self{ .buffer = buffer };
        },
        // assuming posix currently
        else => {
            var src_ptr = @as(
                *align(std.mem.page_size) anyopaque,
                @alignCast(std.c.mmap(null, file_len, mman.PROT_READ, mman.MAP_FILE | mman.MAP_SHARED, file.handle, 0)
            ));

            if (src_ptr == mman.MAP_FAILED) {
                var mmap_result = std.c.getErrno(@intFromPtr(src_ptr));
                if (mmap_result != .SUCCESS) {
                    std.debug.print("mmap errno: {any}\n", .{ mmap_result });
                    @panic("mmap failed");
                }
            }

            const buffer = @as([*]const u8, @ptrCast(src_ptr))[0..file_len];
            return Self{ .buffer = buffer };
        }
    }
}

pub fn free(self: Self, alloc: std.mem.Allocator) void {
    switch (builtin.os.tag) {
        .windows => {
            alloc.free(self.buffer);
        },
        else => {
            const munmap_result = std.c.munmap(@as(
                *align(std.mem.page_size) anyopaque,
                @alignCast(@as(*u8, @ptrCast(self.buffer.ptr)))
            ), self.buffer.len);
            const errno = std.c.getErrno(munmap_result);
            if (errno != .SUCCESS)
                std.debug.panic("munmap err", .{});
        }
    }
}
