---
path: "/blog/docs"
title: "Graphl Docs"
date: "2024-11-22"
---

## Installation

Be sure to read the <a href="/commercial">license</a> which has
implications for commercial usage.

```sh
npm install @graphl/ide
```

## Usage 

```js
import * as graphl from "./WebBackend.js";
import confetti from "@tsparticles/confetti";

// grab the canvas you prepared
const canvas = document.getElementById("my-canvas");

// we define custom nodes separately here
const customFuncs = {
  "Confetti": {
    parameters: [
      {
        name: "particle count",
        type: graphl.Types.i32,
      }
    ],
    results: [],
    impl(particleCount) {
      confetti({
        particleCount,
        spread: 70,
        origin: { y: 0.6 },
      });
    }
  },
};

// give graphl control over that canvas with options
// see the typescript types for all options
const ide = new graphl.Ide(canvas, {
  bindings: {
    jsHost: {
      functions: customFuncs,
    }
  },
  preferences: {
    topbar: {
      visible: false,
    },
  }
});

// execute a function that the user created in the IDE
ide.functions.main();
```
