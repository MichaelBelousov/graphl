import React from 'react'
import Layout from '../components/layout'
import "../shared.css";
import * as constants from "../constants";
import { classNames } from '../react-utils';

const Faqs = () => {
  return (
    <Layout pageTitle="Graphl Commercial" pageDesc="The Graphl License">
      <div>
        <div className="center">
          <h1 style={{ fontSize: "2em" }}>Commercial Usage</h1>
        </div>
        <p>
          You may not distribute a commercial product that embeds the Graphl IDE
          without entering into an agreement with Graphl Technologies or its creator
          Michael Belousov. An incomplete list of examples of "embeddings" includes loading
          the official Graphl IDE in a webview, an iframe, or linking the native SDK into
          an application.
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
          you are beholden only to the restrictions of your distributor, which for
          <a href="https://graphl.tech/app">https://graphl.tech/app</a> is described in the first
          paragraph.
        </p>
        <p>
          You have the exclusive and complete rights to anything you create with an official Graphl IDE,
          and we will never take that away from you. You may export, modify, copy, etc, code that
          you wrote in Graphl. Be sure to check the licenses of any imported code if they have any restrictions
          on usage.
        </p>
        <p>
          Other authorized distributors of an embedded Graphl IDE may not give you the same rights, so
          please refer to their terms.
        </p>

      </div>
    </Layout>
  );
}

export default Faqs
