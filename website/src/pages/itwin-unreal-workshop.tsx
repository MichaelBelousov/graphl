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
    <Layout pageTitle="iTwin Unreal Workshop" pageDesc="The ultimate iTwin/Synchro->Unreal export experience">
      <h2 style={{ textAlign: "center" }}>
        iTwin Unreal Workshop demo
      </h2>

      <p>
        About the demo:
        <ul>
          <li>Free</li>
          <li>Similar features to the discontinued iTwin Exporter for Datasmith, but shouldn't crash. (If it does, contact me!)</li>
          <li>Submit your email below to get an access token and download link within 48 hours</li>
          <li>
            The demo is not yet code-signed (that costs money) so Windows will warn you and you need to bypass that.
            If you want to verify your download, the md5 hash of the demo is FIXME.
          </li>
          <li>There are known bugs! But submit any you find with the help menu</li>
          <li>
            Your access token will permit you to install the demo on a maximum of one machine.
            Please respond to your first email if you have a reason to install the demo on another
            machine
          </li>
          <li>Free demo may be deactivated after a couple months, especially if the iTwin fees I pay prove higher than expected</li>
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
