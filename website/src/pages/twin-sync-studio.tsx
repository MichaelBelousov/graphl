import React from 'react'
import Layout from '../components/layout'
import "../shared.css";
import "./roadmap.css";
import { classNames } from '../react-utils';

const InPageLink = (props: { slug: string } & React.HTMLProps<HTMLAnchorElement> & React.PropsWithChildren<{}>) => {
  return (
    <a
      {...props}
      href={`#${props.slug}`}
      id={props.slug}
      {...classNames("in-page-link", props.className)}
    >
      {props.children}
    </a>
  );
};

const Homepage = () => {
  // TODO: add blurbs to each canvas example
  return (
    <Layout pageTitle="Twin Sync Studio" pageDesc="The ultimate iTwin/Synchro->Unreal tool" className="itue-page-twin-sync-studio">
      <h1 style={{ textAlign: "center" }}> Twin Sync Studio </h1>

      <div className="center" style={{ flexDirection: "column" }}>
        <iframe
          // TODO: make bigger
          width="540"
          height="315"
          src="https://www.youtube.com/embed/NqdFArBRI68?si=cUX3qFzpxGMpv-Db"
          title="YouTube video player"
          frameBorder="0"
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
          referrerPolicy="strict-origin-when-cross-origin"
          allowFullScreen
        />
        <p>
          Video shown with permission from <a href="https://virtuart4d.com/">Virtuart4d</a>,
          using Twin Sync Studio
        </p>
      </div>

      <section>
        <InPageLink slug="early-access-demo"><h2 style={{ textAlign: "center" }}> Early Access Demo </h2></InPageLink>

        <div style={{ textAlign: "center" }}>
          <a href="https://docs.google.com/forms/d/e/1FAIpQLSclHFJbbGW5nGmvV23oECXTfXuy12lmIgSoHbKx9RFLWToo7A/viewform">Request the demo</a>
        </div>

        <ul>
          <li>Submit your email at the link right above to get an access token and download link within 48 hours</li>
          <li>
            Your access token will permit you to install the demo on a maximum of one machine.
            Please respond to your first email if you have a reason to install the demo on another
            machine
          </li>
          <li>It is totally free, but will stop working in June 2025</li>
          <li>
            If you want to try it out, but don't have a Synchro Control project or iTwin, don't worry,
            every demo request response comes with a sample project to try on
          </li>
          <li><a href="https://www.youtube.com/playlist?list=PLsEXIlgQ46lsJEkd6glrD7HDPrcx95YbO" target="_blank">Tutorial videos</a></li>
          <li>
            You cannot use the level sequence-based animation mode in Unreal Engine 5.4 or 5.5, as those versions of Unreal contain
            a bug in Datasmith.
            <br/>
            Luckily, that is not the default animation mode used by Twin Sync Studio, so you can probably ignore this
          </li>
          <li>If you are not on Unreal Engine version 5.3.2, you will need Visual Studio build tools installed to recompile the plugin yourself</li>
          <li>Follow <a href="https://www.linkedin.com/company/graphl-technologies/about">our LinkedIn page</a> for updates
          </li>
          <li><a href="mailto:mike@graphl.tech">Contact us</a> for help or if you run into any issues</li>
        </ul>

      </section>

      <section>
        <InPageLink slug="roadmap"><h2 style={{ textAlign: "center" }}> Roadmap </h2></InPageLink>

        <div className="center">
          <div className="itue-roadmap">
            <div className="itue-roadmap-milestone">
              <h4>June 2025</h4>
              <ul>
                <li>Pro version and support plan release</li>
                <li>Reusable automation scripts for filtering and material mapping</li>
              </ul>
            </div>

            <div className="itue-roadmap-road-vert" />

            <div className="itue-roadmap-milestone">
              <h4>2025 Q3</h4>
              <ul>
                <li>Access model properties (iTwin, Synchro, source) in Unreal Engine</li>
                <li>Access some Synchro schedule data</li>
              </ul>
            </div>

            <div className="itue-roadmap-road-vert" />

            <div className="itue-roadmap-milestone">
              <h4>2025 Q4</h4>
              <ul>
                <li>AI-driven script generation</li>
                <li>Tools for working with huge models</li>
              </ul>
            </div>
          </div>
        </div>
      </section>


      <section>
        <InPageLink slug="roadmap"><h2 style={{ textAlign: "center" }}> Pricing </h2></InPageLink>

        <p>
          A standard pricing model is being worked out and will be set and detailed here by July 2025.
          If you have any questions, please <a href="mailto:mike@graphl.tech">contact us</a>.
        </p>
        <br/>
        <br/>
      </section>
    </Layout>
  );
}

export default Homepage
