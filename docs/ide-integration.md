# IDE Integration

The Graphl IDE can be embedded in web pages to provide basic visual programming capabilities. This is still experimental and has limitations, but it works for simple use cases.

## Installation

```bash
npm install @graphl/ide
```

## Basic Integration

### Simple HTML Page

Here's a minimal example of embedding the IDE:

```html
<!DOCTYPE html>
<html>
<head>
    <title>Graphl IDE Test</title>
    <meta charset="utf-8">
    <style>
        body { margin: 0; padding: 0; }
        #graphl-container { width: 100vw; height: 100vh; }
    </style>
</head>
<body>
    <div id="graphl-container"></div>
    <script type="module">
        import { Ide } from '@graphl/ide';
        
        const container = document.getElementById('graphl-container');
        const ide = await Ide(container);
    </script>
</body>
</html>
```

### React Integration

If you're using React, you can wrap the IDE in a component:

```jsx
import React, { useEffect, useRef } from 'react';
import { Ide, GraphlTypes } from '@graphl/ide';

const hostFunctions = {
    "Add": {
        inputs: [
            { type: GraphlTypes.i32, description: "the first number" },
            { type: GraphlTypes.i32, description: "the second number" },
        ],
        outputs: [{ type: GraphlTypes.i32 }],
        impl: (a, b) => a + b,
        description: "add 2 numbers",
    },
};

export function GraphlIDE() {
    const containerRef = useRef(null);
    const ideRef = useRef(null);

    useEffect(() => {
        ideRef.current = Ide(containerRef.current, { hostFunctions });
        return () => ideRef.current.destroy();
    }, []);

    return (
        <div ref={containerRef} style={{ width: '100%', height: '100%' }} />
    );
}
```

## Configuration Options

### Basic Configuration

```javascript
import { Ide } from '@graphl/ide';

const ide = new Ide(container, {
    // Initial program code
    graphs: `
        (typeof (main) i32)
        (define (main) (return 42))
    `,
    
    // Editor theme
    theme: 'dark', // 'light' or 'dark'
    
    // Show/hide panels
    showTextEditor: true,
    showVisualEditor: true,
    showConsole: true,
    
    // Layout options
    layout: 'horizontal', // 'horizontal' or 'vertical'
});
```

### Host Functions

You can provide JavaScript functions that Graphl programs can call:

```javascript
const ide = new Ide(container, {
    userFuncs: {
        'MyLog': {
            inputs: [{ name: 'message', type: 'string' }],
            outputs: [],
            impl: (message) => console.log('Graphl:', message),
        },
        'GetTime': {
            inputs: [],
            outputs: [{ name: 'timestamp', type: 'f64' }],
            impl: () => Date.now(),
        },
    },
    allowRunning: true,
});
```

## IDE API

### Program Management

```javascript
const ide = new Ide(container);
await ide.initialize();

// Get the current program as text
const sourceCode = await ide.exportGraphlt();

// Compile to WebAssembly
const wasmBytes = await ide.exportWasm();

// Compile and run (if allowRunning is true)
const program = await ide.compile();
if (program && program.functions.main) {
    const result = program.functions.main();
    console.log(result);
}
```

## Limitations

The IDE is experimental and has many limitations:

- **Performance**: Can be slow with larger programs
- **UI Polish**: Basic interface, rough around the edges
- **Browser compatibility**: Only tested in modern browsers
- **Error handling**: May crash or behave unexpectedly
- **Features**: Missing many standard IDE features (autocomplete, refactoring, etc.)
- **Mobile**: Not optimized for touch interfaces
- **Accessibility**: Limited accessibility features

## Current Status

The IDE integration is a proof of concept. It demonstrates the text-visual isomorphism but isn't ready for production use. Expect:

- Bugs and crashes
- Limited functionality
- Changes to the API in future versions
- Performance issues with complex programs

## Next Steps

- [JavaScript SDK](./javascript-sdk.md) - Use the compiler without the IDE
- [Contributing](./contributing.md) - Help improve the IDE
- [Examples](../lang-lib/lang-sdks/js/test/) - See example programs

If you try the IDE integration and run into issues, please report them in the GitHub issues. Your feedback helps us improve the system.
