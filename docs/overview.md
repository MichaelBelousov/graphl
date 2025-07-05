# Graphl Overview

Graphl is a revolutionary programming language that bridges the gap between textual and visual programming through true **text-visual isomorphism**. This means you can seamlessly convert between text-based code and visual node graphs without losing any information or functionality.

## What is Graphl?

Graphl consists of two complementary representations:

- **Graphl**: A visual programming language consisting of graphs of linked nodes that represent execution and data flow
- **Graphlt**: A textual programming language using S-expressions to define functions, variables, and types

The key innovation is that these two representations are **isomorphic** - meaning they contain exactly the same information and can be converted back and forth without any loss of meaning or functionality.

## Text-Visual Isomorphism

Traditional visual programming languages often suffer from limitations:
- Visual representations that can't express all the complexity of text-based code
- One-way conversion from text to visual (but not back)
- Loss of information when switching between representations

Graphl solves these problems through its isomorphic design:

1. **Bidirectional conversion**: Any graphl visual program can be converted to graphlt text, and vice versa
2. **Information preservation**: No data or logic is lost during conversion
3. **Authoritative formatting**: Both representations have canonical formatting rules
4. **Seamless workflow**: Developers can work in whichever representation suits their current task

## Core Features

### Lisp-like Foundation
Graphl is built on a Lisp-like foundation with S-expressions, providing:
- Simple, consistent syntax
- Powerful macro system for graph transformations
- Functional programming paradigms

### WebAssembly Backend
The compiler targets WebAssembly, enabling:
- High-performance execution in browsers
- Easy integration with web applications
- Portable deployment across platforms

### Visual IDE
The embedded visual IDE provides:
- Real-time conversion between text and visual representations
- Interactive node-based editing
- Integrated debugging and execution

### Macro System
Graphl's macro system operates on graphs, enabling:
- Emulation of other graph-based scripting systems
- Visual SQL query building
- Custom workflow engines
- Domain-specific visual languages

## Use Cases

### Educational Programming
- Teach programming concepts through visual representation
- Help students understand data flow and execution order
- Seamlessly transition between visual and textual thinking

### Workflow Automation
- Create visual workflows that compile to efficient WebAssembly
- Build domain-specific visual languages for various industries
- Enable non-programmers to create complex logic visually

### Data Processing
- Visual data pipeline construction
- Real-time data flow visualization
- Integration with existing data processing systems

### Web Development
- Embed visual programming directly in web applications
- Create interactive programming environments
- Build visual configuration interfaces

## Design Philosophy

Graphl is designed with several key principles:

1. **Isomorphism first**: Both representations must be equally expressive
2. **Lightweight**: Minimal overhead for browser deployment
3. **Embeddable**: Easy integration into existing applications
4. **Interoperable**: Seamless integration with other WebAssembly modules
5. **Extensible**: Powerful macro system for customization

## Getting Started

To start using Graphl:

1. **Try the online IDE**: Visit [graphl.tech/app](https://graphl.tech/app) to experiment with the visual editor
2. **Use the JavaScript SDK**: Install `@graphl/compiler-js` to compile graphl programs in Node.js or browsers
3. **Embed the IDE**: Integrate the visual editor into your own applications
4. **Explore examples**: Check out the test suite for comprehensive usage examples

## Next Steps

- [JavaScript SDK Usage](./javascript-sdk.md) - Learn how to use the compiler programmatically
- [IDE Integration](./ide-integration.md) - Embed the visual editor in your applications
- [Contributing](./contributing.md) - Help improve Graphl
- [Roadmap](./roadmap.md) - See what's coming next