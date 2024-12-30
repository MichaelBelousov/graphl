---
path: "/blog/why-are-there-no-visual-scripting-languages"
title: "Why are there no visual scripting languages?"
date: "2025-01-01"
---

## Intro

Why are there no visual scripting languages? You may know the answer here already. There are tons!

Here is a sample of some different visual scripting systems, some you may have heard of:
- [Blender nodes](https://docs.blender.org/manual/en/latest/modeling/geometry_nodes/index.html)
- [Unreal Engine Blueprints](https://dev.epicgames.com/documentation/en-us/unreal-engine/introduction-to-blueprints-visual-scripting-in-unreal-engine)
- [Scratch/Google Blockly](https://developers.google.com/blockly/)
- [Grasshopper](https://www.grasshopper3d.com/page/tutorials-1)
- [retejs.org](https://retejs.org)
- [unit](https://unit.software)
- every no-code workflow engine ever

<!-- TODO: different font -->

So a better question then is, **why can you use languages like JavaScript or Python in websites, browser extensions, servers,
microcontrollers, minecraft, Figma, etc...**

**And yet you can only run Unreal Engine's Blueprint visual scripting language inside the Unreal Engine editor?**
You can't even write your own blueprints and run them in an Unreal Engine-based game!

The answer as far as I can tell is is three fold:
- people don't design visual languages to scale, they create them as a [Domain-Specific Language (DSL)](https://en.wikipedia.org/wiki/Domain-specific_language)
  for users that are less familiar with code
- scripting language are usually implemented using a naive interpreter, assuming they don't need to scale
- Some languages, translate the visual language to a portable language.
  [Rete Studio](https://studio.retejs.org/)) does this, and today they explicitly say it is in beta and recommend you
  _verify that the obtained graph is correctly converted into code that reflects the original code!_<a href="#footnote1"><super>1</super></a>.

I've seen few attempts and little success with the last approach. And on top of that, they're now converting to a language
like JavaScript with its own complex semantics. The simple interpreter approach is easy but slow, so let's ignore it for now.

Why is it hard to convert graphs into languages like JavaScript and Python?
I'll answer that, but first, why shouldn't graph languages suck?

## Can they not suck?

I think so!

The graph is in many ways just a [Control Flow Graph](https://en.wikipedia.org/wiki/Control-flow_graph) inside a compiler.
You could easily make it performant, even compile it to native code such that it's lightning fast. You don't even have to
write a parser!

The hard part is that some people want to be able to convert to a real programming language and back.
Why do people want that? I think it's a social problem. We have a large group of text-editor trained
people (programmers) who want to write their code in text (I am one of them), and we have a large(r) group of
people who don't want the overhead of learning 60 years baggage worth of text input techniques (*cough* vim/emacs),
they just want to click on a socket and be told which functions can be applied to this integer.

I am getting ahead of myself, but I think we can introduce a _new_ textual programming language which
lets us _serialize_ (save) our programs textually, edit them in that format, and then load them back in a graph!
We just need to extend existing languages with some new pieces to make it possible to represent graphs intuitively.

This will allow both traditional text-editor-using programmers and non-programmer low-code users to work together
and customize or integrate their applications in ways that today is inhibited by that (mostly social) divide.

I even optimistically believe this can bring us closer to the dream of truly extensible applications!
Today, 99% of browser users will never make a browser extension even if they have to work with a website daily where they need
to click something 100 times to get their work done.
There's just too much to learn to create an "open selected image in photoshop" button.

But I think the gap will be narrowed significantly if a new visual-first programming language can co-exist with the likes
of Python and JavaScript. And yes, I know about AI<super><a href="#footnote2">2</a></super>.

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

1.  <span id="footnote1"></span> Open the "beta" warning block to read it [https://studio.retejs.org/](https://studio.retejs.org/).
    It truly is a challenging thing, especially converting to a dynamic language.

2.  <span id="footnote2"></span> I will not go into detail right now about AI and coding, many seem to believe that the dawn of
    english-only coding is near, but here is my overall thinking:

    I would suggest the evidence is pointing to us still needing well trained humans deeply involved in the process until
    today's AI compute load becomes significantly cheaper (and uses clean energy).
    The current trajectory of "better" AI seems to include "spend catastrophic amounts of compute to invoke the LLM more times
    for 50% more (decaying) accuracy in each iteration".

    Yes, a small browser extension might be doable, but I think most built-only-by-AI projects will rot.
