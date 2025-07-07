const std = @import("std");
const graphl = @import("graphl");
const testing = std.testing;

const Status = enum (u32) {
  Ok = 0,
  Unknown,
  OutOfMemory,
  BadUsage,

  fn fromError(e: anyerror) @This() {
    switch (e) {
      error.OutOfMemory => .OutOfMemory,
      //else => .Unknown
    }
  }
};

pub export fn graphl_compileSource(
  source_name: ?[*]const u8,
  source_name_len: u32,
  source_text: ?[*]const u8,
  source_text_len: u32,
  in_user_func_json: ?[*]const u8,
  in_user_func_json_len: u32,
  bad_status_message: ?*[*:0]const u8
) Status {
  const user_func_json = if (in_user_func_json) |json_ptr| json_ptr[0..in_user_func_json_len] else "{}";
  var dummy_status_message: [*:0] const u8 = undefined;
  const out_status_message = bad_status_message orelse &dummy_status_message;
  return _graphl_compileSource(
    (source_name orelse return .BadUsage)[0..source_name_len],
    (source_text orelse return .BadUsage)[0..source_text_len],
    user_func_json,
    dummy_status_message,
  );
}

fn _graphl_compileSource(
  source_name: []const u8,
  source_text: []const u8,
  user_func_json: []const u8,
  bad_status_message: *[*:0]const u8
) Status {
  graphl.
}
