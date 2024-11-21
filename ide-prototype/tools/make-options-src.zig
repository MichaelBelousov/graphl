//! for each file argument, create a '{basename}-funcs.gen.zig' file
//! that contains functions for setting that global
//!
//! e.g. a file containing:
//!
//! var x = struct {
//!   y: i32 = 0,
//! };
//!
//! will become:
//! var x = &@import("x.zig").x;
//! export fn setX_y(val: i32) bool {
//!   x.y = val;
//!   return true;
//! }

// TODO: implement this!
