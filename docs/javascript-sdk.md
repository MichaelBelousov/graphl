# JavaScript SDK Usage

The Graphl JavaScript SDK (`@graphl/compiler-js`) provides a complete compiler interface for compiling and executing Graphl programs in Node.js and browser environments.

## Installation

```bash
npm install @graphl/compiler-js
```

## Basic Usage

### Compiling and Running a Simple Program

```javascript
import { compileGraphltSourceAndInstantiateProgram } from '@graphl/compiler-js';

const program = await compileGraphltSourceAndInstantiateProgram(`
  (typeof (add i32 i32) i32)
  (define (add a b) (return (+ a b)))
`);

console.log(program.functions.add(5, 3)); // Output: 8
```

### Backend Options

The SDK supports multiple backends:

```javascript
// Native backend (fastest, requires native compilation)
import { compileGraphltSourceAndInstantiateProgram } from '@graphl/compiler-js/native-backend';

// WebAssembly backend (cross-platform, browser-compatible)
import { compileGraphltSourceAndInstantiateProgram } from '@graphl/compiler-js/wasm-backend';

// Auto-detect backend
import { compileGraphltSourceAndInstantiateProgram } from '@graphl/compiler-js';
```

## Language Features

### Basic Types

Graphl supports several built-in types:

```javascript
const program = await compileGraphltSourceAndInstantiateProgram(`
  (typeof (demo) (i32 string bool f64))
  (define (demo) (return 42 "hello" #t 3.14))
`);

const result = program.functions.demo();
console.log(result); // { 0: 42, 1: "hello", 2: true, 3: 3.14 }
```

### Vectors

```javascript
const program = await compileGraphltSourceAndInstantiateProgram(`
  (typeof (makeVector) vec3)
  (define (makeVector) (return (vec3 1.0 2.0 3.0)))
  
  (typeof (getZ vec3) f64)
  (define (getZ v) (return (.z v)))
`);

const vector = program.functions.makeVector();
console.log(vector); // { x: 1.0, y: 2.0, z: 3.0 }
console.log(program.functions.getZ(vector)); // 3.0
```

### Control Flow

```javascript
const program = await compileGraphltSourceAndInstantiateProgram(`
  (typeof (factorial i32) i32)
  (define (factorial n)
    (if (<= n 1)
        (return 1)
        (return (* n (factorial (- n 1))))))
`);

console.log(program.functions.factorial(5)); // 120
```

### Loops with Labels

```javascript
const program = await compileGraphltSourceAndInstantiateProgram(`
  (typeof (factorialIterative i64) i64)
  (define (factorialIterative n)
    (typeof acc i64)
    (define acc 1)
    <!loop
    (if (<= n 1)
        (return acc)
        (begin
          (set! acc (* acc n))
          (set! n (- n 1))
          >!loop)))
`);

console.log(program.functions.factorialIterative(10n)); // 3628800n
```

## Host Functions

You can provide JavaScript functions that your Graphl program can call:

### Basic Host Function

```javascript
const program = await compileGraphltSourceAndInstantiateProgram(`
  (import Log "host/Log")
  (typeof (main) i32)
  (define (main)
    (begin
      (Log "Hello from Graphl!")
      (return 42)))
`, {
  Log: {
    inputs: [{ type: GraphlTypes.string }],
    outputs: [],
    impl(message) {
      console.log(message);
    }
  }
});

program.functions.main(); // Logs: "Hello from Graphl!"
```

### Host Functions with Return Values

```javascript
import { GraphlTypes } from '@graphl/compiler-js';

const program = await compileGraphltSourceAndInstantiateProgram(`
  (import GetRandomNumber "host/GetRandomNumber")
  (typeof (demo) f64)
  (define (demo) (return (GetRandomNumber)))
`, {
  GetRandomNumber: {
    outputs: [{ type: GraphlTypes.f64 }],
    kind: "pure", // Indicates this function has no side effects
    impl() {
      return Math.random();
    }
  }
});

console.log(program.functions.demo()); // Random number between 0 and 1
```

### Async Host Functions

```javascript
const program = await compileGraphltSourceAndInstantiateProgram(`
  (import FetchData "host/FetchData")
  (typeof (getData) string)
  (define (getData) (return (FetchData "https://api.example.com/data")))
`, {
  FetchData: {
    inputs: [{ type: GraphlTypes.string }],
    outputs: [{ type: GraphlTypes.string }],
    async: true,
    async impl(url) {
      const response = await fetch(url);
      return await response.text();
    }
  }
});

// Note: Function becomes async when using async host functions
const data = await program.functions.getData();
console.log(data);
```

## GraphlTypes Reference

The SDK provides type constants for use in host function definitions:

```javascript
import { GraphlTypes } from '@graphl/compiler-js';

// Numeric types
GraphlTypes.i32    // 32-bit signed integer
GraphlTypes.i64    // 64-bit signed integer (BigInt in JS)
GraphlTypes.u64    // 64-bit unsigned integer (BigInt in JS)
GraphlTypes.f32    // 32-bit float
GraphlTypes.f64    // 64-bit float

// Other types
GraphlTypes.bool   // Boolean
GraphlTypes.string // String
GraphlTypes.vec3   // 3D vector { x, y, z }
GraphlTypes.rgba   // RGBA color (32-bit integer)
GraphlTypes.extern // External data (Uint8Array)
```

## Advanced Features

### Working with External Data

```javascript
const program = await compileGraphltSourceAndInstantiateProgram(`
  (import ProcessData "host/ProcessData")
  (typeof (demo) (extern i32))
  (define (demo) (return (ProcessData) 42))
`, {
  ProcessData: {
    outputs: [{ type: GraphlTypes.extern }],
    impl() {
      return new Uint8Array([1, 2, 3, 4]);
    }
  }
});

const result = program.functions.demo();
console.log(result[0]); // Uint8Array [1, 2, 3, 4]
console.log(result[1]); // 42
```

### RGBA Color Handling

```javascript
const program = await compileGraphltSourceAndInstantiateProgram(`
  (typeof (makeColor) rgba)
  (define (makeColor) (return (rgba 255 128 64 255)))
  
  (typeof (extractRed rgba) i32)
  (define (extractRed color) (return (extract-red color)))
`);

const color = program.functions.makeColor();
console.log(color); // Integer representation of RGBA
console.log(program.functions.extractRed(color)); // 255
```

## Error Handling

The compiler provides detailed error messages for syntax errors:

```javascript
try {
  await compileGraphltSourceAndInstantiateProgram(`
    (define (foo) (return 2)))  // Extra closing paren
  `);
} catch (error) {
  console.error(error.message);
  // "Closing parenthesis with no opener: at unknown:2:34"
}
```

## Testing

The SDK includes comprehensive test examples in `test/e2e.test.ts`. Run tests with:

```bash
bun test
```

## Performance Tips

1. **Use the native backend** when possible for best performance
2. **Mark pure functions** with `kind: "pure"` for optimization opportunities
3. **Use appropriate integer types** (i32 vs i64) based on your needs
4. **Batch operations** when working with host functions to reduce call overhead

## Common Patterns

### State Management

```javascript
const program = await compileGraphltSourceAndInstantiateProgram(`
  (typeof counter i32)
  (define counter 0)
  
  (typeof (increment) i32)
  (define (increment) 
    (begin
      (set! counter (+ counter 1))
      (return counter)))
  
  (typeof (getCounter) i32)
  (define (getCounter) (return counter))
`);

console.log(program.functions.increment()); // 1
console.log(program.functions.increment()); // 2
console.log(program.functions.getCounter()); // 2
```

### Data Processing Pipeline

```javascript
const program = await compileGraphltSourceAndInstantiateProgram(`
  (import ProcessStep1 "host/ProcessStep1")
  (import ProcessStep2 "host/ProcessStep2")
  
  (typeof (pipeline string) string)
  (define (pipeline input)
    (return (ProcessStep2 (ProcessStep1 input))))
`, {
  ProcessStep1: {
    inputs: [{ type: GraphlTypes.string }],
    outputs: [{ type: GraphlTypes.string }],
    impl: (input) => input.toUpperCase()
  },
  ProcessStep2: {
    inputs: [{ type: GraphlTypes.string }],
    outputs: [{ type: GraphlTypes.string }],
    impl: (input) => `Processed: ${input}`
  }
});

console.log(program.functions.pipeline("hello")); // "Processed: HELLO"
```

## Next Steps

- [IDE Integration](./ide-integration.md) - Learn how to embed the visual editor
- [Contributing](./contributing.md) - Help improve the SDK
- [Examples](../lang-lib/lang-sdks/js/test/) - Browse comprehensive test examples