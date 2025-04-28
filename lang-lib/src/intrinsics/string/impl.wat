(module
  (type (;0;) (array (mut i8)))
  (type (;1;) (func (param (ref null 0))))
  (import "env" "str_transfer" (memory (;0;) 1 256))
  (export "__graphl_host_copy" (func $__graphl_host_copy))
  (func $__graphl_host_copy (;0;) (type 1) (param $arr (ref null 0))
    (local $arr_len i32)
    (local $index i32) ;; auto inited to 0

    (local.set $arr_len (array.len (local.get $arr)))

    (loop $loop
      local.get $arr
      local.get $index
      array.get_u 0
      i32.store 

      (local.set $index
        (i32.add
          (local.get $index)
          (i32.const 1)))

      (i32.lt_u
        (local.get $index)
        (local.get $arr_len))
      br_if $loop
    )
  )
  (@custom "sourceMappingURL" (after data) "\07/script")
)
