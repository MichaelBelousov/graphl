# Contributing to Graphl

Thank you for your interest in contributing to Graphl! This guide will help you get started with development and contributing to the project.

## Development Setup

### Prerequisites

- [Zig](https://ziglang.org/) 0.12.0 or later
- [Node.js](https://nodejs.org/) 18+ or [Bun](https://bun.sh/) 1.0+
- [Git](https://git-scm.com/)

### Optional Dependencies

- [wasm-tools](https://github.com/bytecodealliance/wasm-tools) - for WebAssembly tooling
- [Python](https://python.org/) - for some build scripts

### Clone the Repository

```bash
git clone https://github.com/graphl/graphl.git
cd graphl
```

### Install Dependencies

```bash
# Install JavaScript dependencies
npm install
# OR
bun install

# Install dependencies for the JavaScript SDK
cd lang-lib/lang-sdks/js
bun install
cd ../../..

# Install dependencies for the IDE
cd ide
pnpm install
cd ..
```

## Project Structure

```
graph-lang/
├── docs/                    # Documentation
├── lang-lib/               # Core compiler (Zig)
│   ├── src/               # Compiler source code
│   ├── lang-sdks/         # Language SDKs
│   │   └── js/           # JavaScript SDK
│   └── tests/            # Test cases
├── ide/                   # Visual IDE (Zig + TypeScript)
│   ├── src/              # IDE backend (Zig)
│   ├── *.tsx             # IDE frontend (React)
│   └── demo/             # Demo application
└── patches/              # Patches for dependencies
```

## Building the Project

### Build the Compiler

```bash
cd lang-lib
zig build
```

### Build the JavaScript SDK

```bash
cd lang-lib/lang-sdks/js
bun run build
```

### Build the IDE

```bash
cd ide
zig build
npm run build
```

### Run Tests

```bash
# Run JavaScript SDK tests
cd lang-lib/lang-sdks/js
bun test

# Run IDE tests
cd ide
npm test
```

## Development Workflow

### 1. Choose an Issue

- Check the [GitHub Issues](https://github.com/graphl/graphl/issues) for open issues
- Look for issues labeled `good first issue` if you're new to the project
- Comment on the issue to let others know you're working on it

### 2. Create a Branch

```bash
git checkout -b feature/your-feature-name
# OR
git checkout -b fix/your-bug-fix
```

### 3. Make Your Changes

#### For Compiler Changes (Zig)

- Edit files in `lang-lib/src/`
- Run tests: `zig build test`
- Test with the JavaScript SDK: `cd lang-lib/lang-sdks/js && bun test`

#### For JavaScript SDK Changes

- Edit files in `lang-lib/lang-sdks/js/`
- Run tests: `bun test`
- Update TypeScript definitions if needed

#### For IDE Changes

- Backend changes: Edit files in `ide/src/`
- Frontend changes: Edit `.tsx` files in `ide/`
- Run tests: `npm test`
- Test in browser: `npm run dev`

### 4. Test Your Changes

```bash
# Test the compiler
cd lang-lib
zig build test

# Test the JavaScript SDK
cd lang-lib/lang-sdks/js
bun test

# Test the IDE
cd ide
npm test
npm run build
```

### 5. Commit Your Changes

```bash
git add .
git commit -m "feat: add new feature" # or "fix: fix bug"
```

Follow [Conventional Commits](https://www.conventionalcommits.org/) format:
- `feat:` for new features
- `fix:` for bug fixes
- `docs:` for documentation changes
- `test:` for test-related changes
- `refactor:` for code refactoring

### 6. Push and Create a Pull Request

```bash
git push origin feature/your-feature-name
```

Then create a Pull Request on GitHub.

## Code Style Guidelines

### Zig Code

- Follow the [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide)
- Use `zig fmt` to format your code
- Keep functions small and focused
- Use meaningful variable names

### TypeScript/JavaScript Code

- Use TypeScript for type safety
- Follow existing patterns in the codebase
- Use ESLint and Prettier for formatting
- Prefer functional programming patterns

### Documentation

- Update documentation when adding new features
- Use clear, concise language
- Include code examples
- Update the README if needed

## Testing

### Writing Tests

#### JavaScript SDK Tests

Add tests in `lang-lib/lang-sdks/js/test/`:

```typescript
import { compileGraphltSourceAndInstantiateProgram } from "../index.mts";

describe("my feature", () => {
  it("should work correctly", async () => {
    const program = await compileGraphltSourceAndInstantiateProgram(`
      (typeof (myFunction) i32)
      (define (myFunction) (return 42))
    `);
    
    assert.strictEqual(program.functions.myFunction(), 42);
  });
});
```

#### Compiler Tests

Add tests in `lang-lib/src/` using Zig's testing framework:

```zig
test "my feature" {
    // Test code here
}
```

### Running Tests

```bash
# Run all tests
npm test

# Run specific test suite
cd lang-lib/lang-sdks/js
bun test specific-test.test.ts

# Run tests with coverage
bun test --coverage
```

## Debugging

### Debug the Compiler

```bash
cd lang-lib
zig build -Doptimize=Debug
```

### Debug the JavaScript SDK

```bash
cd lang-lib/lang-sdks/js
bun test --inspect
```

### Debug the IDE

```bash
cd ide
npm run dev
# Open browser developer tools
```

## Documentation

### Writing Documentation

- Use Markdown for all documentation
- Place documentation in the `docs/` directory
- Update existing documentation when making changes
- Include code examples and usage patterns

### Building Documentation

Documentation is automatically built and deployed when changes are pushed to the main branch.

## Release Process

### Semantic Versioning

We follow [Semantic Versioning](https://semver.org/):
- `MAJOR`: Breaking changes
- `MINOR`: New features (backward compatible)
- `PATCH`: Bug fixes (backward compatible)

### Creating a Release

1. Update version numbers in `package.json` files
2. Update `CHANGELOG.md`
3. Create a new tag: `git tag v1.0.0`
4. Push the tag: `git push origin v1.0.0`
5. Create a GitHub Release

## Community

### Getting Help

- [GitHub Discussions](https://github.com/graphl/graphl/discussions) - for questions and discussions
- [GitHub Issues](https://github.com/graphl/graphl/issues) - for bug reports and feature requests
- [Discord Server](https://discord.gg/graphl) - for real-time chat

### Code of Conduct

Please be respectful and inclusive. We follow the [Contributor Covenant](https://www.contributor-covenant.org/).

## Common Tasks

### Adding a New Built-in Function

1. Add the function to the compiler in `lang-lib/src/nodes/builtin.zig`
2. Add WebAssembly generation code if needed
3. Add tests in `lang-lib/lang-sdks/js/test/`
4. Update documentation

### Adding a New Type

1. Define the type in `lang-lib/src/compiler-types.zig`
2. Add serialization/deserialization logic
3. Add JavaScript SDK bindings
4. Add tests and documentation

### Adding IDE Features

1. Add backend logic in `ide/src/`
2. Add frontend UI in `ide/*.tsx`
3. Add CSS styling if needed
4. Test in the demo application

## Tips for Contributors

### Performance Considerations

- The compiler targets WebAssembly for performance
- Keep memory allocations minimal
- Use appropriate data structures
- Profile your changes when possible

### Cross-Platform Compatibility

- Test on different operating systems when possible
- Use cross-platform libraries
- Be mindful of file path separators

### Security

- Never commit sensitive information
- Be careful with user input validation
- Follow secure coding practices

## Recognition

Contributors are recognized in:
- The `CONTRIBUTORS.md` file
- GitHub's contributor graph
- Release notes for significant contributions

Thank you for contributing to Graphl! Your contributions help make visual programming more accessible and powerful for everyone.