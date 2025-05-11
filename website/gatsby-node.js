const path = require('path')
const { createFilePath } = require('gatsby-source-filesystem')
const { StatsWriterPlugin } = require("webpack-stats-plugin")

const imageInlineSizeLimit = 4 * 1024

exports.onCreateWebpackConfig = ({ stage, actions, getConfig }) => {
  actions.setWebpackConfig({
    devtool: false,
    /*
    experiments: {
      asyncWebAssembly: true,
    },
    */
    plugins: [
      new StatsWriterPlugin({
        filename: './webpack-stats.json',
        stats: {
          assets: true,
          chunks: true,
          modules: true
        }
      })
    ],
    module: {
      noParse: /\.wasm$/,
      rules: [
        {
          //hack: "NO_MUTATE",
          // "oneOf" will traverse all following loaders until one will
          // match the requirements. When no loader matches it will fall
          // back to the "file" loader at the end of the loader list.
          oneOf: [
            {
              test: /\.wasm$/,
              // REPORTME: why is base64'd wasm soooooo much slower at runtime, not just to load?
              type: "asset/resource"
            },
            // "url" loader works like "file" loader except that it embeds assets
            // smaller than specified limit in bytes as data URLs to avoid requests.
            // A missing `test` is equivalent to a match.
            {
              test: /\.bmp$/,
              loader: require.resolve('url-loader'),
              options: {
                limit: imageInlineSizeLimit,
                name: 'static/media/[name].[hash:8].[ext]',
              },
            },
            {
              test: /\.(gif|png|jpe?g|svg|gl(b|tf))$/i,
              use: [
                //require.resolve('file-loader'), // not sure why this was here but it was breaking images
                require.resolve('image-webpack-loader'),
              ],
            },
            // markdown loading chain
            {
              test: /\.md$/,
              use: [
                require.resolve('html-loader'),
                require.resolve('markdown-loader'),
              ],
            },
          ],
        },
      ],
    },
    resolve: {
      modules: [path.resolve(__dirname, 'src'), 'node_modules'],
      extensions: [
        '.mjs',  '.js',
        '.jsx', //'.wasm',
        '.json', '.ts',
        '.tsx'
      ]
    },
    profile: true,
  })
  // actions.replaceWebpackConfig({
  //   ...getConfig(),
  //   module: {
  //     ...getConfig().module,
  //     rules: getConfig().module.rules.map(rule => {
  //       const newRule = {
  //         ...rule,
  //         ...rule.hack !== "NO_MUTATE" && {
  //           exclude: rule.exclude ? new RegExp(`(${rule.exclude.source})|(\\.wasm$)`) : /\.wasm$/,
  //         },
  //       };
  //       delete newRule.hack;
  //       return newRule;
  //     }),
  //   },
  // });
  //console.log(JSON.stringify(getConfig().module.rules, (_k, v) => v instanceof RegExp ? v.source : v, " "));
}

exports.onCreateNode = ({ node, getNode, actions }) => {
  const { createNodeField } = actions
  if (node.internal.type === 'MarkdownRemark') {
    // XXX: hackily concat to '/blog' since basePath doesn't seem to be working when
    // generating the names
    // FIXME: use node.path
    const slug = createFilePath({ node, getNode, basePath: `blog` })
    createNodeField({ node, name: 'slug', value: `/blog${slug}` })
  }
}

exports.createPages = async ({ graphql, actions }) => {
  const { createPage } = actions
  const result = await graphql(`
    query {
      allMarkdownRemark {
        edges {
          node {
            fields {
              slug
            }
            frontmatter {
              path
            }
          }
        }
      }
    }
  `)
  result.data.allMarkdownRemark.edges.forEach(({ node }) =>
    createPage({
      //path: node.fields.frontmatter.path,
      path: node.fields.slug,
      component: path.resolve('./src/components/BlogPage.tsx'),
      context: {
        slug: node.fields.slug,
      },
    })
  )
}
