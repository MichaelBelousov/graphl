/**
 * SEO component that queries for data with
 *  Gatsby's useStaticQuery React hook
 *
 * See: https://www.gatsbyjs.org/docs/use-static-query/
 */

import React from "react"
import Helmet from "react-helmet"
import { useStaticQuery, graphql } from "gatsby"


function SEO(props: SEO.Props) {
  const description = props.description ?? ""
  const lang = props.lang ?? "en"
  const meta = props.meta ?? []

  const { site } = useStaticQuery(
    graphql`
      query {
        site {
          siteMetadata {
            title
            description
            author
          }
        }
      }
    `
  )

  // FIXME: make sure page title and site title are separate
  const title = props.title ?? site.siteMetadata.title;

  const metaDescription = description || site.siteMetadata.description

  const titleTemplate =
    site.siteMetaData.title === title
      ? '%s'
      : `%s | ${site.siteMetadata.title}`;

  return (
    <Helmet
      htmlAttributes={{
        lang,
      }}
      title={title}
      titleTemplate={titleTemplate}
      meta={[
        {
          name: `description`,
          content: metaDescription,
        },
        {
          property: `og:title`,
          content: title,
        },
        {
          property: `og:description`,
          content: metaDescription,
        },
        {
          property: `og:type`,
          content: `website`,
        },
        {
          name: `twitter:card`,
          content: `summary`,
        },
        ...site.siteMetadata.author ? [
          {
            name: `twitter:creator`,
            content: site.siteMetadata.author,
          }
        ] : [],
        {
          name: `twitter:title`,
          content: title,
        },
        {
          name: `twitter:description`,
          content: metaDescription,
        },
      ].concat(meta)}
    />
  )
}

declare namespace SEO {
  interface Props {
    description?: string;
    lang?: string;
    meta?: {name: string; content: string}[];
    title: string;
  }
}

export default SEO

