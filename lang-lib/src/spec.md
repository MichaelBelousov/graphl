# Graphl(t) Spec

## Graph Encoding/Parsing

### callbacks/functional programming

Directly passing a function as an argument in graphlt is equivalent to a direct execution
in a lambda. This is for parity with the visual representation which must do that

```scm
(define (foreach a (cb x))
  (typeof i i32)
  (define i 0)
  <!if
  (if (>= i a.len)
    (begin
      (cb (get a i))
      (set! i (+ i 1))
      >!if
    )
    return
  )
)

;; the intention here is for array references to be settable...
(define (++ x) (set! x (+ x 1))

;; for loop callback
(define (f a)
  (foreach a
    (lambda (x))
)
```

## Types

## Functions

### Built-in functions

<!-- TODO: table -->

- `+`
- `-`
- `*`
- `/`

## Variables

## Global Variables

## Packaging

### File system layout

Each graphl package is a single file

## Runtime

### Garbage Collection

### Scoping

Graphl has two scopes. Function scope and package scope.

## Standard Library

### Strings

### platform differences

#### Web platform

## Glossary

- `Graphl`: a visual programming language consisting of graphs of linked nodes resembling execution
   and data flow for functions.
- `Graphlt`: a textual programming language consisting of ordered S-expressions to define functions,
  variables and types.
- `formatter`: a program that takes source code and puts the token in a canonical order
- `impure function`: sometimes called a procedure
- `pure function`: a function that can't change any state
- `macro`: a form that is expanded before code generation


