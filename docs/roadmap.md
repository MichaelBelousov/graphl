# Graphl Roadmap

This roadmap outlines what we're working on for Graphl. It's organized by what we think is realistic to achieve in the near term, with more ambitious ideas listed separately.

## Current Status

Graphl is in **early experimental** phase. The core compiler, JavaScript SDK, and basic visual IDE work for simple programs, but there's a lot of polish and functionality missing.

## Near-Term Goals (Next 6 months)

These are things we think we can realistically accomplish soon:

### Language Improvements
- **Better error messages**: More helpful compiler errors
- **String functions**: Basic string manipulation (concat, length, substring)
- **Array/vector support**: Simple list operations
- **Struct types**: User-defined data structures
- **For loops**: Non-label based iteration

### IDE Polish
- **Better visual layout**: Improved node positioning and connections
- **Undo/redo**: Basic edit history
- **Copy/paste**: Node duplication
- **Zoom and pan**: Navigate large programs
- **Better text editor**: Syntax highlighting and basic autocomplete

### Documentation
- **More examples**: Real programs that do useful things
- **Tutorial**: Step-by-step introduction to Graphl
- **Reference docs**: Complete language specification

## Medium-Term Goals (6-12 months)

These would be nice to have but depend on how the near-term work goes:

### Language Features
- **Module system**: Import/export functions between files
- **Type inference**: Automatic type detection
- **Better standard library**: Math, I/O, and utility functions
- **Async support**: Handle asynchronous operations

### IDE Features
- **Debugging**: Step through execution visually
- **Variable inspection**: See values at runtime
- **Performance profiling**: Find bottlenecks
- **Collaborative editing**: Multiple users

### Integration
- **VS Code extension**: Basic syntax highlighting and compilation
- **Better WebAssembly integration**: Sourcemaps and debugging
- **JavaScript interop**: Easier calling of JS functions

## Long-Term Vision (12+ months)

These are directions we'd like to explore, but they're more speculative:

### Advanced Language Features
- **Macro system**: Transform graphs programmatically
- **Multiple backends**: Native compilation, JavaScript output
- **Advanced types**: Generics, unions, optional types
- **Pattern matching**: Destructuring and case analysis

### IDE Vision
- **Multiple views**: Different visualizations of the same program
- **Custom node types**: Domain-specific visual languages
- **Plugin system**: Extensible functionality
- **Mobile support**: Touch-friendly editing

### Platform Integration
- **Native desktop app**: Standalone editor
- **Web platform**: Online IDE with sharing
- **Educational tools**: Classroom-friendly features

## Big Ideas (Maybe Someday)

These are interesting ideas that would require significant research and development:

### AI Integration
- **Code generation**: AI-assisted programming
- **Natural language**: Describe programs in plain English
- **Bug detection**: Automated issue identification
- **Optimization**: AI-driven performance improvements

### Advanced Visualization
- **3D visualization**: Navigate complex programs in 3D
- **Animation**: Show program execution over time
- **VR/AR support**: Immersive programming environments
- **Large-scale programs**: Handle enterprise-sized codebases

### Research Directions
- **Formal verification**: Prove program correctness
- **Distributed programming**: Visual representation of parallel/distributed systems
- **Domain-specific languages**: Build new visual languages on top of Graphl
- **Live programming**: Edit programs while they're running

## How You Can Help

We're a small team and would love contributions:

- **Try it out**: Use Graphl for small projects and report bugs
- **Write examples**: Create interesting programs that showcase features
- **Documentation**: Help improve guides and explanations
- **Code**: Fix bugs or implement features (see [Contributing](./contributing.md))
- **Feedback**: Tell us what you'd like to see prioritized

## Realistic Expectations

Progress will be gradual because:
- **Small team**: Limited development resources
- **Research project**: We're figuring things out as we go
- **Experimental nature**: Some ideas might not work out
- **Real-world constraints**: Everyone has day jobs

This roadmap will change based on what we learn, what works, and what the community finds most valuable. The goal is to be honest about what we can accomplish while staying excited about the possibilities.