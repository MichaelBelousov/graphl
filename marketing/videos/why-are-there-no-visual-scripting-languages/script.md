## Intro

Why are there no visual scripting languages?

You may know the answer here already. There are many!

Shader code for rendering pipelines like Blender, Godot, Unreal Engine, and Unity are often written using visual
languages.

So a better question then is:

Why can you run languages like JavaScript or python in websites, browser extensions, servers, microcontrollers, minecraft, Figma, everywhere,
and yet you can only run Unreal Engine's Blueprint visual scripting language inside the Unreal Engine editor?

The answer as far as I can tell is, anyone that has tried making a portable visual scripting language has done so
by either writing an interpreter in a portable language (like rete.js), or translator from the visual language to a portable language,
and I've seen very limited success writing such translators.

Interpreters are slow but easy, so let's ignore them for now. Why is it hard to convert graphs into languages like JavaScript and Python?

## Why are graph compilers hard

There are several reasons:
- it's tempting to use the language's AST as the graph which is an awkward experience
- ASTs are abstract syntax _trees_, they aren't graphs!
- control flow graphs are graphs, but everybody hates goto <!-- photo of goto considerd unsafe -->

## Shader approach

## Unreal engine blueprint's approach

## why lisp

## lisp macros


