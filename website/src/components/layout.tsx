import React from "react"
import { useStaticQuery, graphql } from "gatsby"
import * as constants from "../constants";

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
    <div>
      <Header />
      <SEO title={pageTitle} description={pageDesc} />
      <div>
        <main>{children}</main>
      </div>
      <footer className="center">
        &copy; {constants.companyName} 2024
      </footer>
    </div>
  )
}
export default Layout
