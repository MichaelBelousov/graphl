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
          <h2>
            Is this a business, what's the catch? Where will you pull the carpet away to make money?
          </h2>
          <ul>
            <li>
              <p>
                We can't pull the rug away even if we wanted to, that's why we've <a href="https://github.com/MichaelBelousov/graphlt">open sourced</a> most of it.
                To remove that temptation.
              </p>
              <p>
                That said, on top of the core, we have a fork for our version of the IDE, <a href="https://graphl.tech/app">https://graphl.tech/app</a>, which
                will have some paid infrastructure like private packages, build farms, scheduled cloud runners, etc.
              </p>
              <p>
                We hope to become sustainable mostly through supporting larger groups adopting Graphl in their workflows and applications.
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
                    (hence zig, WebAssembly and <a href="https://github.com/david-vanderson/dvui">dvui</a>)
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
