const std = @import("std");
const graphl = @import("graphl");
const testing = std.testing;

const Status = enum (u32) {
  Ok = 0,
  Unknown,
  OutOfMemory,
  BadUsage,

  fn fromError(e: anyerror) @This() {
    return switch (e) {
      error.OutOfMemory => .OutOfMemory,
      error.BadUsage => .BadUsage,
      else => .Unknown
    };
  }
};

/// user must free result (with libc free)
pub export fn graphl_compileSource(
  source_name: ?[*]const u8,
  source_name_len: u32,
  source_text: ?[*]const u8,
  source_text_len: u32,
  in_user_func_json: ?[*]const u8,
  in_user_func_json_len: u32,
  /// NOTE: user must free this (with libc free)
  bad_status_message: ?*[*:0]const u8,
  status_code: ?*Status,
  result_len: ?*u32,
) [*]const u8 {
  const user_func_json = if (in_user_func_json) |json_ptr| json_ptr[0..in_user_func_json_len] else "{}";
  var diag = graphl.SimpleDiagnostic{};

  const result = _: {
    break :_ graphl.simpleCompileSource(
      std.heap.c_allocator,
      (source_name orelse break :_ error.BadUsage)[0..source_name_len],
      (source_text orelse break :_ error.BadUsage)[0..source_text_len],
      user_func_json,
      &diag,
    );
  } catch |err| {
    if (bad_status_message) |msg_ptr| {
      msg_ptr.* = std.heap.c_allocator.dupeZ(u8, diag.@"error") catch "c alloc error, don't free me lol";
    }
    if (result_len) |r| r.* = 0;
    if (status_code) |c| c.* = Status.fromError(err);
    return "";
  };

  if (status_code) |c| c.* = .Ok;
  if (result_len) |r| r.* = @intCast(result.len);
  return result.ptr;

}
