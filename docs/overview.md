# Graphl Overview

Graphl is an experimental programming language exploring the idea of **text-visual isomorphism** - the ability to seamlessly convert between text-based code and visual node graphs without losing information.

## What is Graphl?

Graphl has two representations:

- **Graphl**: A visual programming language using connected nodes to represent data and control flow
- **Graphlt**: A textual language using S-expressions (like Lisp) to define functions and data

The core idea is that these two forms are **isomorphic** - they contain the same information and can be converted back and forth without loss.

## Why This Matters

Most visual programming tools can only show simplified versions of code, or only work one way (text to visual). Graphl tries to solve this by:

1. **Bidirectional conversion**: Any visual program can become text, and vice versa
2. **No information loss**: Converting back and forth preserves all details
3. **Choose your view**: Work visually when it helps, or in text when that's clearer

## Current Status

Graphl is in **early experimental** stages. It works, but it's rough around the edges. The core compiler, JavaScript SDK, and basic visual IDE are functional for simple programs.

## Core Features

### Lisp-like Foundation
Built on S-expressions with:
- Simple, consistent syntax
- Functional programming style
- Basic macro system

### WebAssembly Target
Compiles to WebAssembly for:
- Running in browsers
- Decent performance
- Easy integration with web apps

### Visual IDE
A working visual editor that:
- Shows programs as connected nodes
- Converts between text and visual views
- Lets you run and debug programs

## What You Can Do Today

### Educational Use
- Learn programming concepts through visual representation
- See how data flows through programs
- Switch between visual and text views to understand both

### Simple Programs
- Write basic functions and algorithms
- Work with numbers, strings, and booleans
- Build simple data processing pipelines

### Web Integration
- Embed the visual editor in web pages
- Compile programs to WebAssembly
- Call JavaScript functions from Graphl code

## Design Philosophy

Graphl is built around:

1. **Isomorphism first**: Both text and visual must be equally powerful
2. **Keep it simple**: Don't add features that break the core concept
3. **Web-friendly**: Should work well in browsers
4. **Interoperable**: Play nice with existing tools and languages

## Getting Started

To try Graphl:

1. **Clone and build**: Follow the [Contributing Guide](./contributing.md) to set up the development environment
2. **Try the examples**: Look at the test programs in `lang-lib/lang-sdks/js/test/`
3. **Read the SDK docs**: Learn how to use the [JavaScript SDK](./javascript-sdk.md)
4. **Experiment**: Try the visual editor with simple programs

## What's Next

- [JavaScript SDK Usage](./javascript-sdk.md) - How to use the compiler in your own projects
- [IDE Integration](./ide-integration.md) - Embedding the visual editor
- [Contributing](./contributing.md) - Help improve Graphl
- [Roadmap](./roadmap.md) - What we're working on next

## Limitations

Graphl is experimental and has many limitations:
- Small standard library
- Basic type system
- Simple IDE with limited features
- No package system or module imports
- Performance isn't optimized
- Documentation is incomplete

We're working on these, but progress is gradual. This is a learning project exploring what's possible with text-visual isomorphism.