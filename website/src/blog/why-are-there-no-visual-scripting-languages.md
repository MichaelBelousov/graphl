---
path: "/blog/why-do-visual-scripting-languages-suck"
title: "Why do visual scripting languages suck?"
date: "2025-01-01"
---

Why are there no very popular visual scripting languages? This is a trick question... there are plenty!
Here is a sample of some different visual scripting systems, some you may have heard of:

- [Blender nodes](https://docs.blender.org/manual/en/latest/modeling/geometry_nodes/index.html)
- [Unreal Engine Blueprints](https://dev.epicgames.com/documentation/en-us/unreal-engine/introduction-to-blueprints-visual-scripting-in-unreal-engine)
- [Scratch/Google Blockly](https://developers.google.com/blockly/)
- [Grasshopper](https://www.grasshopper3d.com/page/tutorials-1)
- [unit](https://unit.software)
- [nodezator](https://github.com/IndiePython/nodezator)
- every no-code workflow engine ever

And they don't suck, but honestly, I think some parts might suck... kinda.
Why is visual programming so much less popular than textual programming languages like JavaScript and Python, anyway?

Perhaps, a better question might be:

<!-- TODO: different font -->

***Why can you use languages like JavaScript or Python in websites, browser extensions, servers,
microcontrollers, minecraft, Figma, etc... And yet you can only run Unreal Engine's Blueprint visual
scripting language inside the Unreal Engine editor?***

You can't even write your own blueprints and run them in an Unreal Engine-based game!
(although a few mod systems with Epic's blessing seem to have a form of this).

The answer as far as I can tell is three-fold:

1. People don't design visual languages to be used at scale.
   They create them as a [Domain-Specific Language (DSL)](https://en.wikipedia.org/wiki/Domain-specific_language)
   for users that are less familiar with big code-based projects.
2. Visual scripting is usually implemented in a limited scope, with less resources,
   often with a simplistic interpreter since performance isn't a concern
3. Some visual scripts translate to a more common textual language (like JavaScript).
   [Rete Studio](https://studio.retejs.org/)) does this, and today they explicitly say it is in beta, recommending you
   "_verify that the obtained graph is correctly converted into code that reflects the original code"!_<a href="#footnote1"><super>1</super></a>.

I think the real problem is a social intertia one. The people building these things have been using textual
languages since computers had too little memory for anything else, and don't plan on stopping. Very few people
have considered building a visual language for anything serious. No one, as far I can tell, has even made
a visual language that can be freely embedded in other hosts. Even if it "works in any web site", you can't
write a game engine or engineering application that scripts with it.

So instead people chasing serious visual scripting seem to go with option 3. I've seen few attempts and little
success with option 3. And on top of that, they're now converting to a complex language like JavaScript with its
own complex semantics and often heavy-weight runtime dependency.

## Why is it hard to convert visual graphs to an existing language?

How hard can it be to make a graph representation that converts to JavaScript or Python?
I will leave a lot of the detail for a future post, but here is a summary:

- it's tempting to base the visual graph on the language's AST, but ASTs are _Abstract Syntax TREES_, they aren't graphs,
  and they don't represent control flow. Even simplifications of the AST tend to lack things that make visual programming
  attractive.
- In a truly graph-like visual scripting language you can intuitively jump back to previous code sections,
  but the equivalent in programming languages _goto_ is [considered harmful](https://en.wikipedia.org/wiki/Considered_harmful)
  and doesn't truly exist in many languages, including Python and JavaScript.

It's so hard that no one seems to have done it in any usable capacity. Take this small example:

- What do you do with big, twice used expressions?
    - Store a variable? What do you name it? When do you initialize it?
- What do you do when control arbitrarily goes back to an earlier part of the graph?
    - You can't use `goto` in Python or JavaScript, you would need to build a state machine device

So my theory is that the intertia of all these textual languages has prevented builders from
investing in a visual language that can match them. Textual languages are the norm and people
seem to think "you can either learn to code or you can't code".

Then why do people keep building a brand new, limited-scope visual language,
but then also adding Python bindings to their projects?

If only there were a visual language that could be embedded anywhere! (wink, wink).

## Can visual languages not suck?

I think so! I think they almost all leave something to be desired compared to textual languages,
but I think that's because most people implementing them haven't taken them seriously enough.

The visual graph is in many ways just a [Control Flow Graph](https://en.wikipedia.org/wiki/Control-flow_graph) for a compiler.
You could easily make it performant, even compile it to native code such that it's lightning fast. You don't even have to
write a parser (the easy part tbh).

Again, the hard part is that people keep trying to make a visual script that can convert to an existing programming language and back.
We have a large group of text-editor trained
people (programmers) who want to write their code in text (I am one of them), and we have a large(r) group of
people who don't want the overhead of learning a 60 year-old paradigm of text input invented under the baggage of
punch cards, teletype machines, and terminals.

_They just want to click on an integer output and be able to search through the list of functions that apply to integers._

So if we can make a language that both kinds of people can edit, be it text, or visual, _and_ also make it embeddable,
then I think we're getting close to the holy grail of visual scripting.

## The dream of the visual _and_ textual language

I believe we can introduce a _new_ textual programming language which
lets us save our programs textually to a sane, language-like format for text editing,
and then load them back in a graph! We just need to extend existing languages with some new pieces to
make it possible to represent graphs intuitively.

This will allow both traditional text-editor-using programmers and non-programmer low-code users to work together
and customize or integrate their applications in ways that today is inhibited by that sociotechnical divide.

One fly in this ointment that I will discuss in a future post, is the problem of encoding graph node positions
in the textual language, especially if there are people editing this code only via text. Yikes!
I will definitely explain some approaches later.

If we can achieve this truly [isomorphic](https://en.wikipedia.org/wiki/Isomorphism) language though, I believe optimistically
it can bring us closer to the dream of truly extensible applications!
Today, 99% of browser users will never script a browser extension even if they have to work with a website daily where they need
to click something 100 times to get their work done.
There's just too much to learn to create something as simple as an "open selected image in photoshop" button.

I think the gap will be narrowed significantly if a new visual-first programming language can co-exist with the likes
of Python and JavaScript. And if you're thinking about AI, I don't think it
precludes the need for this kind of language.
In fact, I think AI makes it even more useful<super><a href="#footnote3">2</a></super>
as less technical people start writing ---and debugging--- more code.

## Graphl

So all this is really so much fluff to introduce [graphl](https://graphl.tech), what I am designing as
an answer to these problems.

**TODO: show how Graphl solves the above problems**

By designing a language explicitly for textual and visual interpretation, and applying the lessons of
modern software tooling, I believe we can introduce a newcomer to the scripting space that can bring
coding to people never before.

I have seen visual scripting languages inspire smart but code-hating people (architects, game
developers, engineers), and I want to break visual scripting from the chains of their hosts,
and let people make applications extensible with an easy, reusable, standardized language.

If you feel the same way, please, [try Graphl](https://graphl.tech/app), and reach out to me with
how you might want to use it! I want it to be used for everything!

<hr />

Do you think I got something wrong? Please feel free to
[email](me@mikemikeb.com) me to help me make corrections.

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
