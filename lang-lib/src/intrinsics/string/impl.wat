(module
  (type (;0;) (array (mut i8)))
  (type (;1;) (func (param (ref null 0))))
  (import "env" "str_transfer" (memory (;0;)))
  (export "__graphl_host_copy" (func $__graphl_host_copy))
  (func $__graphl_host_copy (;0;) (type 1) (param (ref null 0) $arr)
    (local $arr_len i32)
    (local $index i32)

    i32.const 0
    local.set $index

    array.len $arr
    local.set $arr_len

    loop $loop
      local.get $arr
      local.get $index
      array.get_i8 i32
      i32.store 

      local.get $arr_len
      if 
        br $loop
      end

      local.get $index
      i32.const 1
      i32.add
      local.set $index
    end
  )
  (@custom "sourceMappingURL" (after data) "\07/script")
)
