---
path: "/blog/docs"
title: "Graphl Docs"
date: "2024-11-22"
---

## Installation

```sh
npm install @graphl/ide
```

Note that the API is alpha and subject to change!

## Usage 

```js
import graphl from "@graphl/ide";
import confetti from "@tsparticles/confetti";

// grab the canvas you prepared
const canvas = document.getElementById("my-canvas");

// we define custom nodes separately here
const customFuncs = {
  "Confetti": {
    inputs: [
      {
        name: "particle count",
        type: "i32",
      }
    ],
    outputs: [],
    impl(particleCount) {
      confetti({
        particleCount,
        spread: 70,
        origin: { y: 0.6 },
      });
    }
  },
};

// give graphl control over a canvas with options
// see the typescript types for all options
const ide = new graphl.Ide(canvas, {
  userFuncs: customFuncs,
  graphs: {
    "main": {
      fixedSignature: true,
      outputs: [{
        name: "result",
        type: "i32",
      }],
      nodes: []
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
