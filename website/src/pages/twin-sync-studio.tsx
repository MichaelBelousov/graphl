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
          <li>Request the demo <a href="https://docs.google.com/forms/d/e/1FAIpQLSclHFJbbGW5nGmvV23oECXTfXuy12lmIgSoHbKx9RFLWToo7A/viewform">here</a></li>
          <li>It is totally free, but will stop working in June 2025</li>
          <li>
            If you want to try it out, but don't have a Synchro Control project or iTwin, <a href="mailto:mike@graphl.tech">contact me</a> and I'll
            give you some test files
          </li>
          <li><a href="https://youtu.be/Rlr3CetZ6dQ?si=hyuWOgPsTcqLzALI" target="_blank">Tutorial video</a></li>
          <li>
            Only known to work in Unreal Engine versions 5.0.3 through 5.3.2,
            <br/>
            later Unreal Engine versions have a bug in the level sequence importer, which I have already reported
          </li>
          <li>If you are not on Unreal Engine version 5.3.2, you will need Visual Studio build tools installed to compile the plugin yourself</li>
          <li>
            There are now many options to customize combining of meshes. Combining too much may overrun UE's 2GB static mesh asset limit so that
            may fail. Typically combining is more performant and runs better on older hardware, if you are under that 2GB limit. 
            We recommend the "export merge uninstanced by element" option. The options will be streamlined in the future
          </li>
          <li>Submit your email below to get an access token and download link within 48 hours</li>
          <li>
            The demo is not yet code-signed, so Windows will warn you and you need to bypass that.
            If you want to verify your download, you may request an md5 hash of the installer from support
          </li>
          <li>
            Your access token will permit you to install the demo on a maximum of one machine.
            Please respond to your first email if you have a reason to install the demo on another
            machine
          </li>
          <li>Follow <a href="https://www.linkedin.com/in/michael-belousov-745ab8238/">Mike's LinkedIn</a> for
            updates while we work on adding a roadmap to the website
          </li>
          <li>
            non-iTwin import formats are on the roadmap. Please contact us if you have a format in mind!
          </li>
          <li>Contact <a href="mailto:mike@graphl.tech">mike@graphl.tech</a> for help</li>
        </ul>
      </p>

      <hr/>

      <br/>

      Request the demo <a href="https://docs.google.com/forms/d/e/1FAIpQLSclHFJbbGW5nGmvV23oECXTfXuy12lmIgSoHbKx9RFLWToo7A/viewform">here</a>
    </Layout>
  );
}

export default Homepage
