## ideas

- immutable expressions can be out of order
- reroute nodes are variables
- node comments are variable names
- use single quotes to delimit variables? (to allow for arbitrary text for variable names)
- arrays of size 4 or less automatically have the rgba and xyzw swizzle attributes ala GLSL
- you can sync node graphs
- needs to have a graph layout algorithm for generating a graph from text rather than syncing
- needs to have deterministic automatic naming for node graphs
- maybe fold symmetric expressions
- need an isomorphism for groups but still with the ability to access variables between them
  - or just global variables...

## docs

[glossary](./GLOSSARY.md)

## things we need

- a package manager
- C ffi/binding API
- an IDE (https://github.com/jnmaloney/WebGui) (also see IMNodes)

## Potential names

- graph lang
- Noder
