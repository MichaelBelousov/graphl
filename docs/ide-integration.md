# IDE Integration

The Graphl IDE can be embedded into web applications to provide visual programming capabilities directly in your browser. This guide shows how to integrate the IDE into your own applications.

## Installation

```bash
npm install @graphl/ide
```

## Basic Integration

### Simple HTML Page

Create a basic HTML page with the IDE embedded:

```html
<!DOCTYPE html>
<html>
<head>
    <title>My Graphl App</title>
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
        const ide = new Ide(container);
        
        // Initialize the IDE
        await ide.initialize();
    </script>
</body>
</html>
```

### React Integration

For React applications, you can create a wrapper component:

```jsx
import React, { useEffect, useRef } from 'react';
import { Ide } from '@graphl/ide';

function GraphlIDE({ onProgramChange }) {
    const containerRef = useRef(null);
    const ideRef = useRef(null);

    useEffect(() => {
        if (containerRef.current && !ideRef.current) {
            ideRef.current = new Ide(containerRef.current);
            
            // Initialize the IDE
            ideRef.current.initialize().then(() => {
                console.log('Graphl IDE initialized');
            });

            // Listen for program changes
            ideRef.current.onProgramChange = (program) => {
                onProgramChange?.(program);
            };
        }

        // Cleanup
        return () => {
            if (ideRef.current) {
                ideRef.current.destroy();
                ideRef.current = null;
            }
        };
    }, [onProgramChange]);

    return (
        <div 
            ref={containerRef} 
            style={{ width: '100%', height: '100%' }}
        />
    );
}

export default GraphlIDE;
```

## IDE Configuration

### Basic Configuration

```javascript
import { Ide } from '@graphl/ide';

const ide = new Ide(container, {
    // Initial program code
    initialProgram: `
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

### Advanced Configuration

```javascript
const ide = new Ide(container, {
    // Custom host functions available in programs
    hostFunctions: {
        'MyCustomFunction': {
            inputs: [{ name: 'input', type: 'string' }],
            outputs: [{ name: 'output', type: 'string' }],
            impl: (input) => `Processed: ${input}`,
        },
        'Logger': {
            inputs: [{ name: 'message', type: 'string' }],
            outputs: [],
            impl: (message) => console.log('Graphl:', message),
        }
    },
    
    // Custom types
    customTypes: {
        'MyType': {
            name: 'MyType',
            fields: [
                { name: 'x', type: 'f64' },
                { name: 'y', type: 'f64' }
            ]
        }
    },
    
    // Execution environment
    executionMode: 'wasm', // 'wasm' or 'interpreted'
    
    // File operations
    enableFileOperations: true,
    
    // Debugging
    enableDebugger: true,
});
```

## IDE API

### Program Management

```javascript
const ide = new Ide(container);
await ide.initialize();

// Get current program source
const source = ide.getProgramSource();

// Set program source
ide.setProgramSource(`
    (typeof (greet string) string)
    (define (greet name) (return (str-concat "Hello, " name)))
`);

// Compile and run program
const program = await ide.compileProgram();
const result = program.functions.greet("World");
console.log(result); // "Hello, World"
```

### Event Handling

```javascript
const ide = new Ide(container);

// Program changed event
ide.onProgramChange = (newSource) => {
    console.log('Program updated:', newSource);
    // Save to database, localStorage, etc.
};

// Compilation events
ide.onCompileStart = () => {
    console.log('Compilation started');
};

ide.onCompileSuccess = (program) => {
    console.log('Compilation successful');
};

ide.onCompileError = (error) => {
    console.error('Compilation failed:', error);
};

// Execution events
ide.onExecutionStart = () => {
    console.log('Program execution started');
};

ide.onExecutionComplete = (result) => {
    console.log('Execution completed:', result);
};
```

### Visual Editor Control

```javascript
const ide = new Ide(container);

// Switch between text and visual views
ide.showTextEditor();
ide.showVisualEditor();
ide.showBothEditors();

// Focus on specific functions or variables
ide.focusOnFunction('myFunction');
ide.focusOnVariable('myVariable');

// Add nodes programmatically
ide.addNode({
    type: 'function',
    name: 'newFunction',
    inputs: [{ name: 'x', type: 'i32' }],
    outputs: [{ name: 'result', type: 'i32' }]
});
```

## Styling and Theming

### Custom CSS

```css
/* Override IDE styles */
.graphl-ide {
    --primary-color: #007acc;
    --background-color: #1e1e1e;
    --text-color: #ffffff;
    --border-color: #404040;
}

/* Custom node styles */
.graphl-node {
    border-radius: 8px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.3);
}

.graphl-node.function {
    background-color: #4a90e2;
}

.graphl-node.variable {
    background-color: #f5a623;
}
```

### Theme Configuration

```javascript
const ide = new Ide(container, {
    theme: {
        name: 'custom',
        colors: {
            primary: '#007acc',
            secondary: '#4a90e2',
            background: '#1e1e1e',
            surface: '#252526',
            text: '#ffffff',
            textSecondary: '#cccccc',
            border: '#404040',
            error: '#f44336',
            warning: '#ff9800',
            success: '#4caf50',
        },
        
        // Node styling
        nodes: {
            function: {
                backgroundColor: '#4a90e2',
                borderColor: '#357abd',
            },
            variable: {
                backgroundColor: '#f5a623',
                borderColor: '#e8941b',
            }
        }
    }
});
```

## Integration Examples

### Embedding in a Dashboard

```jsx
import React, { useState } from 'react';
import GraphlIDE from './GraphlIDE';

function Dashboard() {
    const [programOutput, setProgramOutput] = useState('');

    const handleProgramChange = async (source) => {
        try {
            // Compile and run the program
            const program = await compileGraphltSource(source);
            const result = program.functions.main?.();
            setProgramOutput(JSON.stringify(result, null, 2));
        } catch (error) {
            setProgramOutput(`Error: ${error.message}`);
        }
    };

    return (
        <div style={{ display: 'flex', height: '100vh' }}>
            <div style={{ flex: 1 }}>
                <GraphlIDE onProgramChange={handleProgramChange} />
            </div>
            <div style={{ width: '300px', padding: '20px', background: '#f5f5f5' }}>
                <h3>Program Output</h3>
                <pre>{programOutput}</pre>
            </div>
        </div>
    );
}
```

### Educational Platform

```jsx
import React, { useState } from 'react';
import GraphlIDE from './GraphlIDE';

function LearningModule({ lesson }) {
    const [completed, setCompleted] = useState(false);

    const handleProgramChange = async (source) => {
        // Check if the program meets lesson requirements
        const meetsRequirements = await checkLessonRequirements(source, lesson);
        setCompleted(meetsRequirements);
    };

    return (
        <div className="learning-module">
            <div className="lesson-description">
                <h2>{lesson.title}</h2>
                <p>{lesson.description}</p>
                <div className="objectives">
                    {lesson.objectives.map((obj, i) => (
                        <div key={i} className="objective">
                            ✓ {obj}
                        </div>
                    ))}
                </div>
            </div>
            
            <div className="ide-container">
                <GraphlIDE 
                    initialProgram={lesson.startingCode}
                    onProgramChange={handleProgramChange}
                />
            </div>
            
            {completed && (
                <div className="completion-badge">
                    🎉 Lesson Complete!
                </div>
            )}
        </div>
    );
}
```

## Build Configuration

### Vite Configuration

```javascript
// vite.config.js
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
    plugins: [react()],
    
    // Enable WebAssembly
    server: {
        fs: {
            allow: ['..']
        }
    },
    
    // Configure for WebAssembly modules
    optimizeDeps: {
        exclude: ['@graphl/ide']
    },
    
    // Handle WebAssembly files
    assetsInclude: ['**/*.wasm']
});
```

### Webpack Configuration

```javascript
// webpack.config.js
module.exports = {
    // ... other config
    
    experiments: {
        asyncWebAssembly: true,
    },
    
    module: {
        rules: [
            {
                test: /\.wasm$/,
                type: 'webassembly/async',
            },
        ],
    },
};
```

## Performance Optimization

### Lazy Loading

```javascript
// Lazy load the IDE for better initial page load
const loadIDE = async () => {
    const { Ide } = await import('@graphl/ide');
    return new Ide(container);
};

// Load IDE when needed
document.getElementById('load-ide-btn').addEventListener('click', async () => {
    const ide = await loadIDE();
    await ide.initialize();
});
```

### WebWorker Integration

```javascript
// Use Web Workers for compilation
const ide = new Ide(container, {
    useWebWorker: true,
    workerConfig: {
        // Custom worker configuration
        maxWorkers: 2,
        workerTimeout: 30000,
    }
});
```

## Troubleshooting

### Common Issues

1. **WebAssembly not loading**: Ensure your build system supports WebAssembly modules
2. **CORS issues**: Make sure WebAssembly files are served with proper headers
3. **Performance issues**: Consider using Web Workers for heavy computations
4. **Memory issues**: Properly dispose of IDE instances when no longer needed

### Debug Mode

```javascript
const ide = new Ide(container, {
    debug: true,
    logLevel: 'verbose', // 'error', 'warn', 'info', 'verbose'
});
```

## Next Steps

- [JavaScript SDK](./javascript-sdk.md) - Learn about the underlying compiler
- [Contributing](./contributing.md) - Help improve the IDE
- [Examples](https://github.com/graphl/examples) - Browse example integrations