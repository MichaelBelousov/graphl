# Graphl

Graphl is an early programming language and associated embeddable visual IDE
with the following goals:

- allow true isomorphic text and visual editing by carefully designing the textual language
  to be a new kind of lisp with labels and back references
- default to ahead-of-time compilation (currently to WebAssembly) instead of using an interpreter
- bring modern programming language ecosystem design, like package management, to visual scripting
- be embeddable anywhere, in websites, game engines, etc
- allow for graph Domain-Specific-Languages

## [Try it out](https://graphl.tech/graphl/demo)

## What's working

- compiling with control flow, functions
- simple string and numeric types, math operations
- compound (struct) types
- host-defined functions
- JavaScript interop
- saving/opening visual node projects
- visual to text language conversion,

## Help wanted

- more language bindings (currently only JavaScript server and web embeddings exist)
- true generic nodes
- standard library design
- better compiler error UI
- advanced types and type creation UI
- datagrid UI with spreadsheet-like editing of global data structures
- packaging system
- a debugger (or 2)
- macro system rewrite
- rewrite the internals of the IDE so it operates on the text AST directly
- make it easy to wrap lots of existing Wasm, C, JavaScript, and Python, etc. libraries
- port ELK or otherwise tree-formatting of visual nodes
- AI generation of graphl textual code

## Non goals:

- the best programming language to work in textually
