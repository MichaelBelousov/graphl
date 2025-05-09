import React from 'react'
import Layout from '../components/layout'
import "../shared.css";

const Homepage = () => {
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
          <li>You cannot use the level sequence-based animation mode in Unreal Engine 5.4 or 5.5, as those versions contain
            a bug in their Unreal importer.
            <br/>
            Luckily, that is not the default animation mode so you can mostly ignore this.
          </li>
          <li>If you are not on Unreal Engine version 5.3.2, you will need Visual Studio build tools installed to recompile the plugin yourself</li>
          <li>Submit your email below to get an access token and download link within 48 hours</li>
          <li>There are known bugs! But submit any you find in the Graphl help menu or by email</li>
          <li>
            Your access token will permit you to install the demo on a maximum of one machine.
            Please respond to your first email if you have a reason to install the demo on another
            machine
          </li>
          <li>Follow <a href="https://www.linkedin.com/in/michael-belousov-745ab8238/">Mike's LinkedIn</a> for
            updates while we work on adding a roadmap to the website
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
