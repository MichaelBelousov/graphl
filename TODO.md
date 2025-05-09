- create a WASM section reader to read (future) graphl type info out of custom sections
- rewrite the compiler to handle CFGs better and write a slight specification
- add a sourcemap section that maps to graphl code, maybe through graphlt code
  - make it possible to be aware of graphlt spans while editing the graphl
- make it possible to step through the wasm execution from the website itself, using the
  sourcemap to focus and see debug info during execution
