// FIXME: remove
// import resolve from "rollup-plugin-node-resolve";
// import commonjs from "rollup-plugin-typescript";
import typescript from "rollup-plugin-typescript";
import zigar from "rollup-plugin-zigar";
import pkgJson from "./package.json" with { type: "json" };

export default [
  // {
  //   input: "./index.mts",
  //   output: {
  //     name: "graphlt-compiler",
  //     file: pkgJson.browser,
  //     format: 'umd',
  //   },
  //   plugins: [
  //     zigar(),
  //     typescript({
  //       include: "**/*.(|m)ts(|x)",
  //     }),
  //   ],
  // },
  {
    input: "./index.mts",
    plugins: [
      zigar(),
      typescript({
        include: "**/*.(|m)ts(|x)",
        noEmitHelpers: true,
        module: 'ESNext',
        sourceMap: true,
        importHelpers: true
      }),
    ],
    output: [
      // toplevel await by zigar not supported
      //{ dir: "cjs", format: "cjs" },
      { dir: "dist/esm", format: "es" },
    ]
  }
]
