import React from 'react'
import Layout from '../components/layout'
import "../shared.css";
import * as constants from "../constants";
import { classNames } from '../react-utils';
import * as headerStyles from '../components/header.module.scss';

const Faqs = () => {
  return (
    <Layout pageTitle="Graphl Commercial" pageDesc="The Graphl License">
      <div>
        <div className="center">
          <h1 style={{ fontSize: "2em" }}>Commercial Usage</h1>
        </div>
        <div className="center">
          <p>
            Before you read the full license, know two things:
            <ol>
              <li>It is completely free to embed in non-revenue-generating applications.</li>
              <li>You can trivially sign up for a free 12-month trial for commercial applications,
                once per company (but unlimited apps). That trial never incurs any costs, and comes with free support!
              </li>
            </ol>
          </p>
        </div>
        <div className="center" style={{ marginBottom: "1em" }}>
          <a {...classNames(headerStyles.navLink, headerStyles.subButton)}
            target="_blank"
            href="https://docs.google.com/forms/d/e/1FAIpQLSclRZC2PrGcK-Vykq-Ue5Uo0dsBvEqJNpNf8VOqCuUyo4XS0g/viewform?usp=header"
          >
            free 12 month commercial trial
          </a>
        </div>
        <div className="center">
          <h2>The License</h2>
        </div>
        <p>
          You may not distribute a commercial (revenue-generating) product that embeds the Graphl IDE
          without entering into an agreement with Graphl Technologies or its creator
          Michael Belousov. An incomplete list of examples of "embeddings" includes loading
          the official Graphl IDE in a webview, an iframe, loading the IDE bindings in a webpage,
          or linking the native SDK into a non-web application.
        </p>
        <p>
          Embeddings of the Graphl IDE into a non-commercial application is not restricted.
          The owner of this software maintains the exclusive right to determine what is "commercial" software.
          except they may not determine any OSI-approved open source software to be commercial.
        </p>
        <p>
          Advising someone to use an official Graphl IDE (<a href="https://graphl.tech/app">https://graphl.tech/app</a>,
          or the native IDE app distributions) to directly import a library which integrates with a separate commercial entity
          does not constitute an embedding and is therefore unrestricted by this license.
        </p>
        <p>
          You may use the IDE in any application provided to you by an authorized distributor,
          such as <a href="https://graphl.tech/app">https://graphl.tech/app</a> which is free
          to use, but not embed. In fact, if you are just an end-user using the Graphl editor,
          you are beholden only to the restrictions of your distributor, which
          for <a href="https://graphl.tech/app">https://graphl.tech/app</a> is described in the first
          paragraph.
        </p>
        <p>
          You have the exclusive and complete rights to anything you create with an official Graphl IDE,
          and we will never take that away from you. You may export, modify, copy, etc, code that
          you wrote in Graphl. Be sure to check the licenses of any imported code if they have any restrictions
          on usage.
        </p>
        <p>
          Other authorized distributors of a commercially embedded Graphl IDE may not give you the same rights, so
          please refer to their terms.
        </p>

        <div className="center">
          <h2>Examples</h2>
        </div>

        <p>
          The 
          runtime to run game scripts programmed in Graphl. You are completely free to sell that game commercially. However,
          if you wanted players of the game to be able to use Graphl embedded in the game to design custom game logic, that
          would require an agreement with Graphl Technologies.
        </p>


        <p>
          An example is, suppose you make a game where you use Graphl to script some logic, using an independent WebAssembly
          runtime to run game scripts programmed in Graphl. You are completely free to sell that game commercially. However,
          if you wanted players of the game to be able to use the Graphl IDE embedded in the game to design custom game logic, that
          would require an agreement with Graphl Technologies.
        </p>

      </div>
    </Layout>
  );
}

export default Faqs
