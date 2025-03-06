import React from 'react'
import Layout from '../components/layout'
import * as styles from '../components/header.module.scss';
import "../shared.css";
import * as constants from "../constants";
import { classNames } from '../react-utils';
import { useIsMobileLike } from '../useIsMobileLike';

const Homepage = () => {
  const [emailInput, setEmailInput] = React.useState("");

  const emailInputRef = React.useRef<HTMLInputElement>(null);

  // TODO: add blurbs to each canvas example
  return (
    <Layout pageTitle="Twin Sync Studio" pageDesc="The ultimate iTwin/Synchro->Unreal tool">
      <h2 style={{ textAlign: "center" }}>
        Twin Sync Studio demo
      </h2>

      <p>
        About the demo:
        <ul>
          <li>Free</li>
          <li>Only known to work in Unreal Engine versions 5.0.3 through 5.3.2,
            <br/>
            later Unreal Engine versions have a bug in the level sequence importer, I have submitted a bug report.
          </li>
          <li>You must have visual studio installed to use the plugin (if you don't need a combined export, you can avoid it).</li>
          <li>Similar features to the discontinued iTwin Exporter for Datasmith, but crashes much less on large data. (If it does, contact me!)</li>
          <li>Submit your email below to get an access token and download link within 48 hours</li>
          <li>
            The demo is not yet code-signed, so Windows will warn you and you need to bypass that.
            If you want to verify your download, the md5 hash of the installer is <code><pre>4d7810965a70238ee11b33fb30be2c58</pre></code>.
          </li>
          <li>There are known bugs! But submit any you find in the Graphl help menu or by email</li>
          <li>
            Your access token will permit you to install the demo on a maximum of one machine.
            Please respond to your first email if you have a reason to install the demo on another
            machine
          </li>
          <li>Free demo may stop working in June, 2025</li>
          <li>Follow <a href="https://www.linkedin.com/in/michael-belousov-745ab8238/">Mike's LinkedIn</a> for
            updates while we work on adding a roadmap to the website
          </li>
          <li>Contact <a href="mailto:mike@graphl.tech">mike@graphl.tech</a> for help</li>
          <li>Tutorial video is in progress</li>
        </ul>
      </p>

      <hr/>

      <br/>

      Request the demo <a href="https://docs.google.com/forms/d/e/1FAIpQLSclHFJbbGW5nGmvV23oECXTfXuy12lmIgSoHbKx9RFLWToo7A/viewform">here</a>
    </Layout>
  );
}

export default Homepage
