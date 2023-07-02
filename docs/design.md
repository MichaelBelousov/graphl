
# Design

## Achieving Parity

### Positioning

An important part of parity is sanely positioning nodes as people would want to, the same way a code formatter makes people
forget about syntactical positioning.

#### Flow

Graph flow is horizontal right-going in blender.

#### Trees formatting

All nodes will be laid out horizontally with identical (adjustable via pragma?) vertical and horizontal distances,
with minimal intersecting links.
All groups will be laid out in the same fashion as nodes using external links.
A separate file can be generated for people wanting to preserve original node positions.

#### Orphan nodes as comments

<!-- I suppose I need screenshots... -->

Often times people will leave orphan nodes as alternative paths through the graph as a form of
comment that they had tried or will try that instead.

They are often vertically aligned since the flow of the graph is horizontal.

Detecting this is difficult, probably as a start, will use a weighted vertical symmetry check
and place the orphan code as a comment above.

The above solution is somewhat unaligned with achieving parity but more aligned with semantic intent.

### Meanings and conventions in nodes

- orphan nodes are vertically aligned comments
- reroute nodes imply intermediate variables... this isn't always true
- reused outputs imply an intermediate variable
- groups are used as variable names

```graphlang


;; need to look at a typed lisp, assume for now i32 allows you to define bindings that only accept an i32
(define (max (i32 a) (i32 b))
  (if (> a b) a b))

;; type arguments?
(define (max (type n) (n a) (n b))
  (if (> a b) a b))

(define (subgraph (vec4 color) (vec4 color))
  (group "name"
    (define x 5)
    (define y (+ 10 x)))
  (group)
  )
```

### Intended competition

- Unreal Engine Blueprint compatibility
- Blender geometry nodes compatibility
- other visual scripting systems?

### Ideas

- LLVM
- C ffi

### node-group conversions:

#### branch then join

```dot
digraph branch {
  branch [label="exec<br/>cond"];
  branch -> A;
  branch -> B;
  A -> C
  B -> C
  C -> D
  D -> E
}
```

```lisp

(if cond
  A
  B)
C
D
E
```

#### segment sequence

This is hard because `a->b->c` is different in the visual realm from `sequence(->a ->b ->c)`,
but in the text realm those are mostly the same

```dot
digraph segmentSequence {
  X -> A
  A -> B
  B -> C
  sequence -> A
  sequence -> D
}
```

idea 1:

```lisp
;; segment is duplicated... not idiomatic in text realm...
(begin (x)
       (a)
       (b)
       (c))
(begin (begin (a) (b) (c))
       (begin (d)))
```

idea 2:

```lisp
(define A (a) (b) (c))
(begin (x)
       (A))
;; double begin (sequence) is not idiomatic
(begin (begin (A))
       (begin (d)))
```

##### how about backwards?

Maybe it's OK if we consider that integrating this technology into existing blueprints
will change them slightly... doubly-entered segments can be extracted to a function or macro
for better composability if they do not have clean rejoins
<!-- TODO: better define which kinds of double-entered segments can't be rejoined...
     maybe an early return will suffice in most cases so that remaining paths
     can join. -->

```lisp
(begin
  (f)
  (g)
  ;!
  (set! x 10)
  (h x))
```

idea 1:
```dot
digraph segmentSequenceBackwards {
  f -> g
  g -> setx
  setx -> h
}
```

Maybe instead of supporting sequences we can do vertical reroutes?
