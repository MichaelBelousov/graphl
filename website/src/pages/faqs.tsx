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
          <h2>Why not open source? <br/> Why would people use a closed source programming language?</h2>
          <ul>
            <li>
              <p>
                I will write more about this on my personal blog, but at its core,
                I want to be able to work on this full-time but feed my kids. I think I can do 
                that reasonably without making it free for commercial usage immediately.
                I don't believe I can do that if I start this as open source.
              </p>
              <p>
                Also, one of my design goals has been to make sure that the visual programs
                can be cleanly isomorphic to a textual language, and I am committed to
                open sourcing everything at that layer. The visual IDE though I am not
                committed to open sourcing at the moment.
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
                You can use the IDE (website or desktop app) we distribute for free to write,
                execute and export anything to run anywhere. But you cannot embed the Graphl IDE
                in your own app and then make money off that app without first entering into
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
