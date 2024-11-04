import React, { useLayoutEffect } from "react"
import Layout from "./layout"
import Helmet from "react-helmet"
import { graphql } from "gatsby"
import SEO from "./seo"

import * as styles from "./blog.module.scss"

export default function BlogPost(props: any) {
  const post = props.data.markdownRemark

  return (
    <Layout pageTitle={post.frontmatter.title}>
      <SEO title={post.frontmatter.title} description={post.frontmatter.description} />
      {/*
      <Helmet>
        <link
          rel="stylesheet"
          href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/9.15.10/styles/paraiso-dark.min.css"
          crossOrigin="anonymous"
        />
      </Helmet>
      */}
      <div className={styles.post}>
        <h1 className="center">{post.frontmatter.title}</h1>
        <h3 className="center">{post.frontmatter.date}</h3>
        <br />
        <div dangerouslySetInnerHTML={{ __html: post.html }} />
      </div>
    </Layout>
  )
}

export const query = graphql`
  query($slug: String!) {
    markdownRemark(fields: { slug: { eq: $slug } }) {
      html
      frontmatter {
        title
        path
        date(formatString: "MMMM D, YYYY")
      }
    }
  }
`
