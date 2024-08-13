const builtin = @import("builtin");
const std = @import("std");

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
            //var src_ptr = try std.os.mmap(null, file_len, std.os.PROT.READ, std.os.MAP.SHARED, file.handle, 0);
            const src_ptr = try std.posix.mmap(null, file_len, std.posix.PROT.READ, .{ .TYPE = .SHARED }, file.handle, 0);
            const buffer = @as([*]const u8, @ptrCast(src_ptr))[0..file_len];
            return Self{ .buffer = buffer };
        },
    }
}

pub fn free(self: Self, alloc: std.mem.Allocator) void {
    switch (builtin.os.tag) {
        .windows => {
            alloc.free(self.buffer);
        },
        else => {
            std.posix.munmap(@alignCast(self.buffer));
        },
    }
}
