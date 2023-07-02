
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


fn SubGraph(a: i32[4], b: b1[4]) f32[2] {
  /// group: 1
  // regular comment
  const simpleVariable = 52.f;
  const 'long variable' = 10.f;
  const 'eye length' = atan2('var ref', simpleVariable);
  /// end group
  
  /// group: group with a more interesting comment
  const 'var ref' = 'long variable' * a; // referenced above
  /// end group

  // OR

  group X {
    const 'my var' = 5f;
  }

  group Y {
    const 'my var' = 10u32 + X.'my var'
  }
}

fn main(ctx: Context) Result {
  return Result {
    .surface = Glossy * SubGraph(ctx.uv ++ ctx.uv, {true, false ,false, false});
  };
}
```

### Intended competition

- Unreal Engine Blueprint compatibility
- Blender geometry nodes compatibility
- other visual scripting systems?

### Ideas

- LLVM
- C ffi

### node-group conversions:

```txt
digraph branch {

}
```

