// FIXME: remove
import typescript from "rollup-plugin-typescript";
import zigar from "rollup-plugin-zigar";
import define from "rollup-plugin-define";
import pkgJson from "./package.json" with { type: "json" };

const optimize = process.env.NODE_ENV === "development" ? "Debug" : "ReleaseSmall";

export default [
  // {
  //   input: "./index.mts",
  //   output: {
  //     name: "graphlt-compiler",
  //     file: pkgJson.browser,
  //     format: 'umd',
  //   },
  //   plugins: [
  //     zigar({
  //       optimize: "ReleaseSmall",
  //       topLevelAwait: false,
  //     }),
  //     typescript({
  //       include: "**/*.(|m)ts(|x)",
  //     }),
  //   ],
  // },
  {
    input: "./index.mts",
    plugins: [
      define({
        replacements: {
          "globalThis._GRAPHL_JS_NATIVE": JSON.stringify(false),
        },
      }),
      zigar({
        optimize,
        //embedWASM: true, // fetch wasm by default
        nodeCompat: true,
        // FIXME: topLevelAwait is very convenient but it means we can't set the WASI instance
        // ourselves... consider figuring out how to re-enable it
        topLevelAwait: false,
      }),
      typescript({
        include: "**/*.(|m)ts(|x)",
      }),
    ],
    output: [
      {
        dir: "dist/esm",
        format: "es",
        sourcemap: true,
      },
    ]
  },
  {
    input: "./index.mts",
    plugins: [
      zigar({
        optimize,
        //embedWASM: true, // fetch wasm by default
        topLevelAwait: false,
        nodeCompat: true,
      }),
      typescript({
        include: "**/*.(|m)ts(|x)",
      }),
    ],
    output: [
      {
        dir: "dist/cjs",
        format: "cjs",
        sourcemap: true,
      },
    ]
  }
]
