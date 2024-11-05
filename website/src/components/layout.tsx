import React from "react"
import { useStaticQuery, graphql } from "gatsby"
import * as constants from "../constants";
import "./layout.module.scss";

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
  return (
    <div style={{ position: "relative" }}>
      <Header />
      <SEO title={pageTitle} description={pageDesc} />
      <div>
        <main>{children}</main>
      </div>
      <footer className="center" style={{ position: "fixed", bottom: 0 }}>
        &copy; {constants.companyName} 2024
      </footer>
    </div>
  )
}
export default Layout
