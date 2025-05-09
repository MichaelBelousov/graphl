import React from 'react'
import Layout from '../components/layout'
import "../shared.css";
import * as styles from "./index.module.scss";
import { Link } from 'gatsby';
import * as constants from "../constants";
import Logo from "../images/GraphlAnimation.inline.svg";
import { classNames } from '../react-utils';

const Homepage = () => {
  return (
    <Layout pageTitle="Graphl Technologies" pageDesc="Graphl Technologies builds true visual programming for all">
      <p style={{ textAlign: "center" }}>
        <div
          className={styles.bigText}
          style={{
            fontSize: "2em",
            textAlign: "center",
            display: "flex",
            justifyContent: "center",
            alignItems: "center",
            gap: "10px",
            margin: "12px 0",
          }}
        >
          <Logo className={styles.logoImage} />
          {constants.companyShortName}
        </div>
        is a provider of no-code solutions in generic and construction software.
      </p>

      <p>
        As part of building domain solutions like <Link to="/twin-sync-studio">Twin Sync Studio</Link> for
        our customers, we build <Link to="/graphl-lang">Graphl</Link>, a universal, embeddable,
        and <a href="https://github.com/MichaelBelousov/graphlt">open source</a> visual
        programming environment.
      </p>

      <p>
        Founded by Michael Belousov, our mission is to build the standard, open,
        visual programming environment, one that breaks boundaries to match
        or outclass traditional text-only programming paradigms, and integrates
        flawlessly with AI tools.
      </p>

      <p style={{ textAlign: "center" }}>
        Questions?
        Reach out to Mike at <a href={`mailto:mike@graphl.tech`}>mike@graphl.tech</a>
      </p>

    </Layout>
  );
}

export default Homepage
