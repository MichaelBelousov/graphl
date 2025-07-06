# JavaScript SDK Usage

The Graphl JavaScript SDK lets you compile and run Graphl programs in Node.js and browsers. It's still experimental but functional for basic use cases.

## Installation

```bash
npm install @graphl/compiler-js
```

## Basic Usage

### Simple Example

```javascript
import { compileGraphltSourceAndInstantiateProgram } from '@graphl/compiler-js';

const program = await compileGraphltSourceAndInstantiateProgram(`
  (typeof (add i32 i32) i32)
  (define (add a b) (return (+ a b)))
`);

console.log(program.functions.add(5, 3)); // Output: 8
```

### Backend Options

The SDK has two backends:

```javascript
// WebAssembly backend (works everywhere, including browsers)
import { compileGraphltSourceAndInstantiateProgram } from '@graphl/compiler-js/wasm-backend';

// Native backend (faster, Node.js only)
import { compileGraphltSourceAndInstantiateProgram } from '@graphl/compiler-js/native-backend';

// Auto-detect (uses native in Node.js, WebAssembly in browsers)
import { compileGraphltSourceAndInstantiateProgram } from '@graphl/compiler-js';
```

## Language Features

### Basic Types

Graphl supports these types:

```javascript
const program = await compileGraphltSourceAndInstantiateProgram(`
  (typeof (demo) (i32 string bool f64))
  (define (demo) (return 42 "hello" #t 3.14))
`);

const result = program.functions.demo();
console.log(result); // { 0: 42, 1: "hello", 2: true, 3: 3.14 }
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

### Labels and Loops

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

You can call JavaScript functions from Graphl:

### Simple Host Function

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
    kind: "pure", // No side effects
    impl() {
      return Math.random();
    }
  }
});

console.log(program.functions.demo()); // Random number between 0 and 1
```

## Type Reference

```javascript
import { GraphlTypes } from '@graphl/compiler-js';

// Numbers
GraphlTypes.i32    // 32-bit signed integer
GraphlTypes.i64    // 64-bit signed integer (BigInt in JS)
GraphlTypes.u64    // 64-bit unsigned integer (BigInt in JS)
GraphlTypes.f32    // 32-bit float
GraphlTypes.f64    // 64-bit float

// Other types
GraphlTypes.bool   // Boolean
GraphlTypes.string // String
GraphlTypes.vec3   // 3D vector { x, y, z }
GraphlTypes.rgba   // RGBA color (4 channel 8-bit per color)
GraphlTypes.extern // External data (any JavaScript object)
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

### RGBA Colors

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

## Limitations

The SDK is experimental and has limitations:

- **Error messages**: Often cryptic or unhelpful
- **Performance**: Not optimized for speed
- **Type system**: Basic, missing many features
- **Standard library**: Very limited built-in functions
- **Debugging**: Hard to debug compiled programs

## Next Steps

- [IDE Integration](./ide-integration.md) - Embed the visual editor
- [Examples](../lang-lib/lang-sdks/js/test/) - Look at test cases for more examples
- [Contributing](./contributing.md) - Help improve the SDK