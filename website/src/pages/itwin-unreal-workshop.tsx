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
            Your access token will permit you to install the demo on a maximum of one machine.
            Please respond to your first email if you have a reason to install the demo on another
            machine.
          </li>
          <li>Follow <a href="https://www.linkedin.com/in/michael-belousov-745ab8238/">Mike's LinkedIn</a> for
            updates while we work on adding a roadmap to the website
          </li>
          <li>Contact <a href="mailto:mike@graphl.tech">mike@graphl.tech</a> for help</li>
          <li>Tutorial video is in progress</li>
        </ul>
      </p>

      <form
        style={{ display: "flex", gap: "20px", justifyContent: "center" }}
        action={`https://docs.google.com/forms/d/e/1FAIpQLSdIbJ7Ye-J5fdLjuLjSIqx6B7YKTQJfI8jk3gNTIc4CVw9ysg/formResponse?submit=Submit&usp=pp_url&entry.633639765=${emailInput}&entry.522288266=nofeedback`}
        method="POST"
        target="hidden-target-frame"
        onSubmit={(_e) => {
          // TODO: check if successful!
        }}
      >
        Request the demo!
        <input
          className={styles.subInput}
          ref={emailInputRef}
          value={emailInput}
          onChange={e => setEmailInput(e.currentTarget.value)}
          placeholder="you@example.com"
          type="email"
        />
        <input value="submit" className={styles.subButton} type="submit"></input>
        <iframe style={{ display: "none" }} name="hidden-target-frame" />
      </form>
    </Layout>
  );
}

export default Homepage
