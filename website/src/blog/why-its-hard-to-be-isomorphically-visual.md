---
path: "/blog/why-its-hard-to-be-isomorphically-visual"
title: "Why being both a textual and visual language is hard"
date: "2025-01-01"
---

## Why do visual scripting languages suck?

Why are there no very popular visual scripting languages?
You may know the answer here already. There are tons!

Here is a sample of some different visual scripting systems, some you may have heard of:
- [Blender nodes](https://docs.blender.org/manual/en/latest/modeling/geometry_nodes/index.html)
- [Unreal Engine Blueprints](https://dev.epicgames.com/documentation/en-us/unreal-engine/introduction-to-blueprints-visual-scripting-in-unreal-engine)
- [Scratch/Google Blockly](https://developers.google.com/blockly/)
- [Grasshopper](https://www.grasshopper3d.com/page/tutorials-1)
- [unit](https://unit.software)
- [nodezator](https://github.com/IndiePython/nodezator)
- every no-code workflow engine ever

And they don't suck, although maybe some parts of some of them do. So a better question then is:

<!-- TODO: different font -->

***Why can you use languages like JavaScript or Python in websites, browser extensions, servers,
microcontrollers, minecraft, Figma, etc... And yet you can only run Unreal Engine's Blueprint visual
scripting language inside the Unreal Engine editor?***

You can't even write your own blueprints and run them in an Unreal Engine-based game!
(although a few mod systems with Epic's blessing seem to have a form of this).

The answer as far as I can tell is is three fold:
- People don't design visual languages to be used at scale.
  They create them as a [Domain-Specific Language (DSL)](https://en.wikipedia.org/wiki/Domain-specific_language)
  for users that are less familiar with big code-based projects.
- Visual scripting is usually implemented in a limited scope, with less resources,
  often with a simplistic interpreter since performance isn't a concern
- Some visual scripts translate to a more common textual language (like JavaScript).
  [Rete Studio](https://studio.retejs.org/)) does this, and today they explicitly say it is in beta, recommending you
  "_verify that the obtained graph is correctly converted into code that reflects the original code"!_<a href="#footnote1"><super>1</super></a>.

I've seen few attempts and little success with the last approach. And on top of that, they're now converting to a 
non-visual language like JavaScript with its own complex semantics. The simple interpreter approach is easy but slow,
and I think just a consequence of the project goals, so I think we can ignore it for now.

But why is it hard to convert graphs into languages like JavaScript and Python?
I plan to answer that in more detail in a future post.
For now, I'll answer the question of can they not suck?

## Can they not suck?

I think so!

The visual graph is in many ways just a [Control Flow Graph](https://en.wikipedia.org/wiki/Control-flow_graph) inside a compiler.
You could easily make it performant, even compile it to native code such that it's lightning fast. You don't even have to
write a parser (the easy part tbh).

The hard part is that some people want to be able to convert to a real programming language and back.
Why do people want that? I think it's a social problem. We have a large group of text-editor trained
people (programmers) who want to write their code in text (I am one of them now), and we have a large(r) group of
people who don't want the overhead of learning a 60 year-old paradigm of text input invented under the baggage of
punch cards, teletype machines, and terminals.

_They just want to click on an integer output and be able to search through the list of functions that apply to integers._

## The dream of the isomorphic visual _and_ textual language

I believe we can introduce a _new_ textual programming language which
lets us _serialize_ (save) our programs textually to a sane, language-like format for text editing,
and then load them back in a graph! We just need to extend existing languages with some new pieces to
make it possible to represent graphs intuitively.

This will allow both traditional text-editor-using programmers and non-programmer low-code users to work together
and customize or integrate their applications in ways that today is inhibited by that sociotechnical divide.

I even optimistically believe this can bring us closer to the dream of truly extensible applications!
Today, 99% of browser users will never script a browser extension even if they have to work with a website daily where they need
to click something 100 times to get their work done.
There's just too much to learn to create something as simple as an "open selected image in photoshop" button.

But I think the gap will be narrowed significantly if a new visual-first programming language can co-exist with the likes
of Python and JavaScript. And if you're thinking about AI, I don't think it
precludes the need for this kind of language. In fact, I think AI makes it even more necessary<super><a href="#footnote2">2</a></super>.

## Problems to solve

## Why are graph-to-language compilers hard?

Ok, so I mentioned briefly we need a new language. Why can't we use current languages?

There are several reasons:
- it's tempting to use the language's AST as the visual graph, but ASTs are _Abstract Syntax TREES_, they aren't graphs,
  and they were not designed for intuitive visual use. Even generalizations of the AST are not intuitive, you basically
  have to know how the underlying language works
- In a truly graph-like visual scripting language you can intuitively jump back to previous code sections,
  but the equivalent in programming languages _goto_ is [considered harmful](https://en.wikipedia.org/wiki/Considered_harmful)
  and doesn't truly exist in many languages, including Python/JavaScript.

## using data twice

As an example, consider how someone might convert the following graph to JavaScript.

Ok, so maybe data isn't the problem.

## using code twice

As an example, consider how someone might convert the following graph to JavaScript.

<!-- -->

How do you go back to the other code after?
Without goto, in JavaScript you have to implement your own state machine, which is...
not really how a JavaScript programmer would ever do it.

```ts
function graph(input: integer): integer {
    const state: 0 | 1 | "done" = 0;

    let counter = 5;

    while (state !== "done") {
        switch (state) {
            case 0: {
                if (counter > 0) {
                    foo();
                    counter -= 1;
                } else {
                    state = 1;
                }
            } break;
            case 1: {
                bar();
                state = "done";
            } break;
        }
    }
}
```

Now if you're a programmer, you might be thinking, "Hey, that's just a while loop!".
But someone just writing an algorithm intuitively without knowing structured programming,
might hear about a while loop and say, "Hey! That's just a jump back to the condition!".

So-called "structured programming" is less important when you can literally see the control
flow graph in front of you...

### Isomorphism

And after all that difficulty turning graphs into high-level code, some people really want to be able to convert
that javascript _back_ into the original graph! How preposterous...

That's what an isomorphism is, a conversion of something from one form into another, that is perfectly reversible
without losing any detail.

Imagine taking the above state machine JavaScript code and converting it back into a graph. Doable? Perhaps...
Will your compiler convert all while+switch state machines into graph code?
What if someone added a new state?
What if they refactored it to not use a state machine?

## What about a new language?

## Control flow

## Why Lisp

## Lisp macros

<hr />

There is a _lot_ out there, so maybe I got something wrong, please feel free to
[email](mike@graphl.tech) me to help me make corrections.

Footnotes:

1.  <span id="footnote1"></span> Open the "beta" warning block to read it [https://studio.retejs.org/](https://studio.retejs.org/).
    It truly is a challenging thing so I don't blame them, you're converting to a language with separate semantics and potentially
    backwards, while trying to be readable on both ends...

2.  <span id="footnote2"></span> I will not go into detail right now about AI and coding, many seem to believe that the dawn of
    english-only coding is near, but here is my overall thinking:

    I would suggest the evidence is pointing to us still needing well trained humans deeply involved in the process until
    today's AI compute load becomes significantly cheaper (and uses clean energy).
    The current trajectory of "better" AI seems to include "spend catastrophic amounts of compute to invoke the LLM hundreds of times
    for 50% more (decaying) accuracy in each iteration".

    Yes, a small browser extension might be doable, but I think most built-only-by-AI projects will rot, and still need debugging by
    humans. And a visual language's debugger will be _much_ easier for the less technically endowed.
