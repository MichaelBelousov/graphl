import React from 'react'
import Layout from '../components/layout'
import "../shared.css";
import * as constants from "../constants";
import { classNames } from '../react-utils';

const Faqs = () => {
  return (
    <Layout pageTitle="Graphl FAQs" pageDesc="Frequently asked questions about Graphl">
      <div>
        <div className="center">
          <h1 style={{ fontSize: "2em" }}>FAQs</h1>
        </div>

        <div>
          <h2>How is it pronounced?</h2>
          <ul>
            <li>
              <p>
                Graph-uhl.
              </p>
            </li>
          </ul>
        </div>

        <div>
          <h2>I don't like the license</h2>
          <ul>
            <li>
              <p>
                Not a question, but, please <a href="mailto:me@mikemikeb.com">reach out to me</a> and let's discuss!
              </p>
              <p>
                Do please read the other relevant FAQ though.
              </p>
            </li>
          </ul>


          <h2>
            Why source-available?
            <br/>
            Aren't all programming language's open source now?
          </h2>
          <ul>
            <li>
              <p>
                One of my design goals has been to make sure that the visual programs
                can be cleanly isomorphic to a textual language, and I am committed to
                open sourcing everything at that layer. The visual IDE though I am not
                committed to open sourcing at the moment.
              </p>
              <p>
                I will write more about this on my personal blog, but at its core,
                I would love to be able to work on this full-time and feed my kids at the same time.
                I think I can do that reasonably without making it free for commercial usage immediately.
                I think I can do that faster this way.
              </p>
              <p>
                I'd heavily consider open sourcing everything if we can achieve a sustainable
                model for it. If you really disagree with my reasoning please reach out, I'd love
                to chat.
              </p>
            </li>
          </ul>

          <h2>What are the usage restraints?</h2>
          <ul>
            <li>
              <p>
                Go read the <a href="/commercial">license</a>.
              </p>
              <p>
                If you want to use it commercially, there's a big 12-month trial period.
              </p>
            </li>
          </ul>

          <h2>How is this different from other visual scripting languages?</h2>
          <ul>
            <li>
              <p>
                The project has a few goals to circumvent the problems of many visual scripting languages:
                <ol>
                  <li>The IDE and runtime should be portable to almost all systems
                    (hence zig, WebAssembly and [dvui](https://github.com/david-vanderson/dvui))
                  </li>
                  <li>
                    The language should be deterministically interchangeable with a textual language (graphlt), this means a few things:
                    <ol>
                      <li>
                        Existing text based tools (like version control or classical text editors) can be used without issue.
                        (I myself really want to be able to edit people's nodes in vim!)
                      </li>
                      <li>
                        Both the text language (graphlt) and the node language should
                        use strict but fair deterministic formatters to eliminate the need for people editing
                        the text to have to declare node positions, and to also prevent merge conflicts on node
                        position changes.
                      </li>
                      <li>
                        Certain concepts like backwards node edges must be disallowed or limited very carefully
                        to prevent overly complex node formatting algorithms.
                      </li>
                    </ol>
                  </li>
                  <li>
                    The graph macro system allows emulating other visual scripting systems in the language!
                  </li>
                  <li>
                    Control flow, types, and objects will be a first class citizen.
                  </li>
                </ol>
              </p>
            </li>
          </ul>


        </div>
      </div>
    </Layout>
  );
}

export default Faqs
