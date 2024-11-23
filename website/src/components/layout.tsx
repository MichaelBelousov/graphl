import React from "react"
import { useStaticQuery, graphql } from "gatsby"
import * as constants from "../constants";
import { Link } from 'gatsby';
import "@fontsource/quicksand/400.css"
import * as styles from "./layout.module.scss";

import Header from "./header"
import SEO from "./seo"

interface LayoutProps {
  pageTitle: string
  pageDesc: string
}

const Layout = ({
  pageTitle,
  pageDesc,
  children,
}: React.PropsWithChildren<LayoutProps>) => {

  React.useLayoutEffect(() => {
    // HACK! restore overflow handling after using app
    document.body.style.overflow = "initial";
  }, []);

  return (
    // NEXT: add links to footer
    <div className={styles.layoutContainer} style={{ position: "relative" }}>
      <Header />
      <SEO title={pageTitle} description={pageDesc} />
      <div className={styles.layoutMiddle}>
        <main>{children}</main>
      </div>
      
      <footer style={{ position: "relative", bottom: 0 }}>
        <div className={styles.footerLinks}>
          <div className={styles.linkColumn}>
            <a target="_blank" href="https://docs.google.com/forms/d/e/1FAIpQLSdIbJ7Ye-J5fdLjuLjSIqx6B7YKTQJfI8jk3gNTIc4CVw9ysg/viewform?usp=sf_link">subscribe</a>
          </div>
          <div className={styles.linkColumn}>
            <Link replace={false} to="/blog/docs">docs</Link>
          </div>
          <div className={styles.linkColumn}>
            <a target="_blank" href="https://www.npmjs.com/package/@graphl/ide">npm</a>
          </div>
          <div className={styles.linkColumn}>
            <a target="_blank" href="https://www.linkedin.com/in/michael-belousov-745ab8238/">LinkedIn</a>
          </div>
        </div>
        <span>&copy; Michael Belousov</span>
        {/*<span>&copy; {constants.companyName} 2024</span> */}
      </footer>
    </div>
  )
}
export default Layout
