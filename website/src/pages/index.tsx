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
        {[
          ShinyLogo,
          <strong>is the cloud SQL solution</strong>,
          <strong>that is really cheap</strong>,
          <div>
            {/* TODO: need an image! */}
            <p className={styles.bigText} style={{ textAlign: "center" }}>
              Blah blah blah
            </p>

            <p className={styles.bigText} style={{ textAlign: "center" }}>
              Join our <a target="_blank" href="https://e0a075ca.sibforms.com/serve/MUIFANC3EaFwNn2Lb330eR8CUoK52Kqq3Iw805_JEf19NtNbXgz8blNJHfE7RaKNJADeNfGAkMOKu86zmyUy_B8V1ivmiigESd_rQkaChA0dM3eST4ictTcvmsCZXQ2ec4b_xS9nXdaF4S1fOmDeDInPn7hFEVTEiHlExtWpPGNEiPcJXdBTlt7MRtajeVcdJGC3u3dBacXZcMsz">
                newsletter
              </a> to receive product updates.
            </p>

            <p style={{ textAlign: "center" }}>
              Questions?
              <br />
              Reach out to us at <MailLink email="support@torakku.io" />
            </p>
          </div>,
        ].map((e, i, arr) => {
            // FIXME: do not add space in big thingy
            const addSpace = i < arr.length - 1;
            const Tag = typeof e === "function" ? e : "span" as const;

            const result = (
              <div>
                <Tag key={i} className={styles[`fadeInText_${i}`]}>
                  {typeof e === "function" ? undefined : e}
                </Tag>
                {addSpace && " "}
              </div>
            );

            return result;
          })}
      </div>
    </Layout>
  )
}

export default Homepage
