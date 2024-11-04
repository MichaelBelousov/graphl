import React from 'react';
import Layout from '../components/layout'
import { MailLink } from '../components/MailLink';
import "../shared.css";
import * as styles from "./roadmap.module.scss";
import { classNames } from '../react-utils';

const Homepage = () => {
  return (
    <Layout pageTitle="Pricing">
      <p>
        We have the following plans
      </p>

      <div className="center">
        <div {...classNames(styles.roadmapMilestones, "full-size")}>
          <div>
            <em>Trial</em>
            <strong>Free</strong>
            <p>Scan your site once for free</p>
          </div>
          <div>
            <em>Standard</em>
            <strong>$5/mo</strong>
            <p>Run up to 3 scans a week</p>
          </div>
          <div>
            <em>Enterprise</em>
            <strong><a href="mailto:support@torakku.io">Custom</a></strong>
            <p>Unlimited scans, source access</p>
          </div>
        </div>
      </div>
    </Layout>
  )
}

export default Homepage
