import React from "react"
import { useStaticQuery, graphql } from "gatsby"
import * as constants from "../constants";
import { Link } from 'gatsby';
import "@fontsource/quicksand/400.css"
import * as styles from "./layout.module.scss";
import { classNames } from "../react-utils";

import Header from "./header"
import SEO from "./seo"

interface LayoutProps {
  pageTitle: string
  pageDesc: string
}

const Footer = () => (
  <footer>
    <div className={styles.footerLinks}>
      <div className={styles.linkColumn}>
        <a target="_blank" href="https://docs.google.com/forms/d/e/1FAIpQLSdIbJ7Ye-J5fdLjuLjSIqx6B7YKTQJfI8jk3gNTIc4CVw9ysg/viewform?usp=sf_link">subscribe</a>
        <a target="_blank" href="https://www.linkedin.com/company/graphl-technologies/about">LinkedIn</a>
        <a target="_blank" href="mailto:mike@graphl.tech">Email</a>
      </div>
      <div className={styles.linkColumn}>
        {/* TODO: change name to twin-sync export */}
        <a target="_blank" href="https://www.npmjs.com/package/@graphl/ide">npm</a>
        <Link replace={false} to="/twin-sync-studio">AEC</Link>
        <Link replace={false} to="/blog/docs">docs</Link>
      </div>
    </div>
    <span>&copy; {new Date().getFullYear()} {constants.companyFullName}</span>
  </footer>
);

const Layout = (props: React.PropsWithChildren<LayoutProps> & React.HTMLProps<HTMLDivElement>) => {
  const { pageTitle, pageDesc, children } = props;

  console.log(props, {...classNames(styles.layoutContainer, props.className)})

  React.useLayoutEffect(() => {
    // HACK! restore overflow handling after using app page
    document.body.style.overflow = "initial";
  }, []);

  return (
    <div {...classNames(styles.layoutContainer, props.className)} style={{ position: "relative", ...props.style }}>
      <Header />
      <SEO title={pageTitle} description={pageDesc} />
      <div className={styles.layoutMiddle}>
        <main>{children}</main>
      </div>
      
      <Footer />
      <div id="graphl-overlay" />
    </div>
  )
}
export default Layout
