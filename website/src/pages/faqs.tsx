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
          <h2>Why not open source? <br/> Isn't it a programming language?</h2>
          <ul>
            <li>
              <p>
                I will try to write more about this more on my personal blog, but I don't think
                I can guarantee as good of a future for this project starting all of it in
                open source.
              </p>
              <p>
                One of my design goals has been to make sure that the visual programs
                can be cleanly isomorphic to a textual language, and I am committed to
                open sourcing everything at that layer. The visual IDE though I am not
                sure.
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
                Go read the <a href="/FIXME">license</a>, but the short of it is:
              </p>
              <p>
                You may not distribute a commercial product that embeds the Graphl IDE.<br/>
                You can use the IDE (website or desktop app) we distribute for free to write
                and execute anything locally. But you cannot embed the Graphl IDE in your own app
                and then make money off that app without first entering into
                a <a href="/commercial">commercial agreement</a> with Graphl Technologies.
              </p>
            </li>
          </ul>

        </div>
      </div>
    </Layout>
  );
}

export default Faqs
