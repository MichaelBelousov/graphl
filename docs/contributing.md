# Contributing to Graphl

Thanks for your interest in Graphl! This is an experimental project exploring text-visual programming, and we'd love your help making it better.

## Ways to Contribute

You don't need to be an expert to help:

- **Try it out**: Use Graphl and use the help/report button to report what breaks or confuses you
- **Fix bugs**: Start with small issues to get familiar with the codebase
- **Suggest features**: Tell us what you'd like to see
- **Use it**: Tell us where and how you might want to use Graphl

## Development Setup

### Prerequisites

- [Zig](https://ziglang.org/) 0.14.0 - The main language for the compiler
- [Node.js](https://nodejs.org/) 20+ or [Bun](https://bun.sh/) 1.0+ - For the JavaScript SDK and build tools
- [Git](https://git-scm.com/) - For version control

### Optional but Helpful

- [wasm-tools](https://github.com/bytecodealliance/wasm-tools) - For WebAssembly debugging
- [Python](https://python.org/) - Some build scripts use Python

### Getting Started

2. **Install JavaScript dependencies**
   ```bash
   bun install  # or npm install
   ```

3. **Try building the project**
   ```bash
   # Build the core compiler
   cd lang-lib
   zig build
   
   # Build the JavaScript SDK
   cd lang-sdks/js
   bun run build
   
   # Run tests to make sure everything works
   bun run test
   ```

## Project Structure

```
graph-lang/
├── docs/                 # Documentation (what you're reading now)
├── lang-lib/             # Core compiler written in Zig
│   ├── lang-sdks/        # Language integration SDKs
│   │   └── js/           # JavaScript SDK
│   └── ...
└── ide/                  # Visual IDE (Zig + JavaScript glue for web)
```
