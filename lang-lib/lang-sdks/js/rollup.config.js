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
      zigar({
        optimize: "ReleaseSmall",
        //embedWASM: true, // fetch wasm by default
      }),
      typescript({
        include: "**/*.(|m)ts(|x)",
      }),
    ],
    output: [
      { dir: "dist/esm", format: "es" },
    ]
  },
  {
    input: "./index.mts",
    plugins: [
      zigar({
        optimize: "ReleaseSmall",
        //embedWASM: true, // fetch wasm by default
        topLevelAwait: false,
      }),
      typescript({
        include: "**/*.(|m)ts(|x)",
      }),
    ],
    output: [
      { dir: "dist/cjs", format: "cjs" },
    ]
  }
]
