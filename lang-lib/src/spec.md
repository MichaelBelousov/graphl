# Graphl(t) Spec

## Graph Encoding/Parsing

### Graph execution order and referring to previous nodes

- every node has a "return value".
- that value is not accessible if you haven't "reached" that node yet.
- using future node values from a previous one gives you garbage
- pure node paths can be used anywhere since they can be executed without regards to order
- if you're in a loop so you go back to a previous execution

### how do you "access" previous nodes in the text language?

You value-reference the label:

```scm
(define (f x)
  (begin
    100 <!used-twice ;; add a label
    &!used-twice ;; reference its value
  ))
```

Having two links to an output means it is auto-labeled and pulled out to before
its first usage.

```scm
(define (f x)
  (begin
    100 <!used-twice
    (+ (* &!used-twice 0.5)
       &!used-twice)
  ))
```

If you only have one link, its usage is inlined.

```scm
(define (f x)
  (begin
    (+ 1.0 (* 100 0.5))
  ))
```


You can also jump to a label:

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


