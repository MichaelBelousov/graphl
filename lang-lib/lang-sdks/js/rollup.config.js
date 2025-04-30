// FIXME: remove
import typescript from "rollup-plugin-typescript";
import zigar from "rollup-plugin-zigar";
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
      zigar({
        optimize,
        //embedWASM: true, // fetch wasm by default
        nodeCompat: true,
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
