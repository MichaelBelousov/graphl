import React from 'react'
import ReactDOM from 'react-dom';
import Layout from '../../components/layout'
import "../../shared.css";
// TODO: move roadmap into this dir
import "../roadmap.css";
import { InPageLink } from '../../components/InPageLink';
import Modal from '../../components/modal'
import * as headerStyles from '../../components/header.module.scss';

let modalContainer: HTMLDivElement | undefined = undefined;

const TwinSyncStudioPage = () => {
  // FIXME: gross workaround for hydration being rejected because the rendered result isn't the same
  React.useEffect(() => {
    if (typeof document !== "undefined") {
      modalContainer = document.getElementById("graphl-overlay") as HTMLDivElement;
    }
  }, []);

  const [purchaseRequestOpen, setPurchaseRequestOpen] = React.useState(false);

  return (
    <Layout pageTitle="Twin Sync Studio" pageDesc="The ultimate iTwin/Synchro->Unreal tool" className="itue-page-twin-sync-studio">
      <h1 style={{ textAlign: "center", fontSize: "2rem" }}> Twin Sync Studio </h1>

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
          A standard pricing model will be set and detailed here in July 2025.
          Until then, if you're ready to use Twin Sync Studio commercially,
          please <a 
            href="https://docs.google.com/forms/d/e/1FAIpQLSct5LNo2cT1HzbKhe45Ik60cp-U5CvGqWi0-tT8Dy7lqRGWTQ/viewform"
            onClick={(e) => {
              e.preventDefault();
              setPurchaseRequestOpen(prev => !prev);
            }}
          >
            make a purchase request
          </a> for pricing information.
        </p>
        <br/>
        <br/>

        {modalContainer && ReactDOM.createPortal(
          <PurchaseRequestModal isOpen={purchaseRequestOpen} setIsOpen={setPurchaseRequestOpen} />,
          modalContainer
        )}
      </section>
    </Layout>
  );
};

const PurchaseRequestModal = (props: {
  isOpen: boolean,
  setIsOpen: React.Dispatch<React.SetStateAction<boolean>>,
}) => {
  const emailInputRef = React.useRef<HTMLInputElement>(null);


  // TODO: use a batteries-included form framework
  const [emailInput, setEmailInput] = React.useState("");
  const [companyNameInput, setCompanyNameInput] = React.useState("");
  const [machineAllowanceInput, setMachineAllowanceInput] = React.useState("");

  React.useEffect(() => {
    if (emailInputRef.current && props.isOpen) {
      emailInputRef.current.focus();
    }
  }, [props.isOpen])


  return (
    <Modal isOpen={props.isOpen} setIsOpen={props.setIsOpen}>
      {/* HACK to prevent weird browser behavior */}
      <iframe style={{ display: "none" }} name="hidden-target-frame" />
      <form
        className="itue-purchase-form"
        action={
          "https://docs.google.com/forms/d/e/1FAIpQLSct5LNo2cT1HzbKhe45Ik60cp-U5CvGqWi0-tT8Dy7lqRGWTQ/formResponse?submit=Submit&usp=pp_url"
          + `&entry.1717367917=${encodeURIComponent(emailInput)}`
          + `&entry.1784948496=${encodeURIComponent(companyNameInput)}`
          + `&entry.1501421878=${machineAllowanceInput}`
        }
        method="POST"
        target="hidden-target-frame"
        onSubmit={(_e) => {
          // TODO: check if successful!
          props.setIsOpen(false);
        }}
      >

        <label>
          Email:
          <input
            className={headerStyles.subInput}
            ref={emailInputRef}
            value={emailInput}
            onChange={e => setEmailInput(e.currentTarget.value)}
            placeholder="you@example.com"
            type="email"
          />
        </label>

        <label>
          Company Name:
          <input
            className={headerStyles.subInput}
            value={companyNameInput}
            onChange={e => setCompanyNameInput(e.currentTarget.value)}
            placeholder="Your Awesome Company"
          />
        </label>


        <label>
          Machine Count Desired:
          <input
            className={headerStyles.subInput}
            value={machineAllowanceInput}
            onChange={e => setMachineAllowanceInput(e.currentTarget.value)}
            placeholder="1"
            type="number"
          />
        </label>

        <input value="submit" className={headerStyles.subButton} type="submit"></input>
      </form>
    </Modal>
  );
};

export default TwinSyncStudioPage;
