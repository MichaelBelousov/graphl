// fake build-cfg to allow dual building zigar output and local tests with `zig build`

pub const module_name = "fake";
pub const module_dir = "fake";
pub const stub_path = "./src/main.zig";
pub const module_path = "./src/main.zig";
pub const is_wasm = false;
pub const use_libc = false;
pub const output_path = "/tmp/nope";
