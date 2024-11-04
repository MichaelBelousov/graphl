import React from 'react'
import Layout from '../components/layout'
import "../shared.css";
import * as styles from "./index.module.scss";
import { MailLink } from '../components/MailLink';
import * as constants from "../constants";
import { classNames } from '../react-utils';

const ShinyLogo = (divProps: React.HTMLProps<HTMLDivElement>) => {
  const {className, ...rest} = divProps;
  return (
    <strong {...classNames(styles.logoAnimated, className)} {...rest}>
      {constants.flagshipProductName}
    </strong>
  );
};

const Homepage = () => {
  return (
    <Layout pageTitle="Home">
      <div {...classNames(styles.bigText)} style={{ textAlign: "center" }}>
        {/* TODO: wrap this in a component/function to make it readable */}
        <ShinyLogo className={"fadeInText_0"} />
        <div>
          <strong className={"fadeInText_1"}>is the only no-code solution</strong>
          {" "}
          <strong>that is still code</strong>.
        </div>

        {[
          <div>
            {/* TODO: need an image! */}
            <p className={styles.bigText} style={{ textAlign: "center" }}>
              Throw away 60 years of text editing baggage and write code <em> without writing code</em>
            </p>

            <p className={styles.bigText} style={{ textAlign: "center" }}>
              Want to understand what your AI generated?
              <br/>
              <em> Debug visually </em>
            </p>

            <p className={styles.bigText} style={{ textAlign: "center" }}>
              Experience the merging of workflows with optimized code.
            </p>

            <p style={{ textAlign: "center" }}>
              Questions?
              <br />
              Reach out to us at <MailLink email="support@grappl.online" />
            </p>
          </div>,
        ].map((e, i, arr) => {
            // FIXME: do not add space in big thingy
            const addSpace = i < arr.length - 1;
            const Tag = typeof e === "function" ? e : "span" as const;

            const result = (
              <React.Fragment key={i}>
                <Tag key={i} className={styles[`fadeInText_${i}`]}>
                  {typeof e === "function" ? undefined : e}
                </Tag>
                {addSpace && " "}
              </React.Fragment>
            );

            return result;
          })}
      </div>
    </Layout>
  )
}

export default Homepage
