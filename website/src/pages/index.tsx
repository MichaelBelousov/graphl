import React from 'react'
import Layout from '../components/layout'
import "../shared.css";
import * as styles from "./index.module.scss";
import { MailLink } from '../components/MailLink';
import * as constants from "../constants";
import { classNames } from '../react-utils';
import type * as Graphl from "@graphl/ide";
import Logo from "../images/GraphlAnimation.inline.svg";
import { confetti } from '@tsparticles/confetti';
import { useStaticQuery, graphql } from 'gatsby';

const graphl = import("@graphl/ide");

const ShinyLogo = (divProps: React.HTMLProps<HTMLDivElement>) => {
  const {className, style, ...rest} = divProps;
  return (
    <h1 {...classNames(styles.logoAnimated, className)} style={{ margin: 0, ...style}} {...rest}>
      {divProps.children}
    </h1>
  );
};

const ShinyButton = (btnProps: React.HTMLProps<HTMLAnchorElement>) => {
  const {className, ...rest} = btnProps;
  return (
    <a href="app" {...classNames(styles.logoAnimated, className)} {...rest}>
      {btnProps.children}
    </a>
  );
};

type Sexp = number | string | {symbol: string} | Sexp[];

const sexpToSql = (sexp: Sexp) => {
  if (Array.isArray(sexp)) {
    let sql = "";

    const [func, ...params] = sexp as [{symbol: string}, ...Sexp[]];

    const handlePrev = () => {
      if (!Array.isArray(params[0]))
        return;
      const execParam = params.shift() as Sexp;
      const prev = sexpToSql(execParam);
      sql += prev;
      sql += '\n';
    };

    if (func.symbol === "SELECT") {
      handlePrev();
      params.forEach(p => { if (typeof p !== "string") throw Error(`bad SELECT arg: ${p}`); })
      sql += sexpToSql(func) + ' ' + params.join(',');

    } else if (func.symbol === "WHERE") {
      handlePrev();
      sql += sexpToSql(func) + ' ' + params.map(sexpToSql).join(',');

    } else if (func.symbol === "FROM") {
      handlePrev();
      params.forEach(p => { if (typeof p !== "string") throw Error(`bad FROM arg: ${p}`); })
      sql += sexpToSql(func) + ' ' + params.join(',');

    } else if (func.symbol === "string-equal") {
      handlePrev();
      sql += `${sexpToSql(params[0])} = ${sexpToSql(params[1])}`;

    } else if (func.symbol === "like") {
      handlePrev();
      sql += `${sexpToSql(params[0])} LIKE ${sexpToSql(params[1])}`;

    } else if (func.symbol === "==") {
      handlePrev();
      sql += `${sexpToSql(params[0])}=${sexpToSql(params[1])}`;

      // assume it's a binary operator
    } else {
      handlePrev();
      sql += `${sexpToSql(params[0])} ${sexpToSql(func)} ${sexpToSql(params[1])}`;

    }

    return sql;

  } else if (typeof sexp === "object" && "symbol" in sexp) {
    return sexp.symbol;

  } else if (typeof sexp === "string") {
    return `'${sexp}'`

  } else if (typeof sexp === "number") {
    return `${sexp}`

  } else {
    console.error(sexp);
    throw Error("unexpected value:");
  }
};

const customNodes: Record<string, Graphl.JsFunctionBinding> = {
  "Confetti": {
    parameters: [{"name": "particleCount", type: /*graphl.Types.i32*/ 0 }],
    results: [],
    impl(particleCount: number) {
      confetti({
        particleCount,
        spread: 70,
        origin: { y: 0.6 },
      });
    }
  },
  "query-string": {
    parameters: [{ name: "nodes", type: 5/*grappl.Types.code*/ }],
    results: [{ name: "query", type: 4/*grappl.Types.string*/}],
    impl(code) {
      // TODO: print the formed sql query
    }
  },
  // dummy nodes
  "SELECT": {
    parameters: [{ name: "column", type: 4 /*grappl.Types.string*/ }],
    results: [],
    // TODO: remove empty impl to indicate dummy
    impl() {},
  },
  "WHERE": {
    parameters: [{ name: "condition", type: 6/*grappl.Types.bool*/ }],
    results: [],
    impl() {},
  },
  "FROM": {
    parameters: [{ name: "table", type: 4 /*grappl.Types.string*/ }],
    results: [],
    impl() {},
  },
};

const sharedOpts: Partial<Graphl.Ide.Options> = {
  bindings: {
    jsHost: {
      functions: customNodes,
    },
  },
  preferences: {
    graph: {
      scrollBarsVisible: false,
      scale: 0.7,
    },
    definitionsPanel:  {
      visible: false,
    },
    topbar: {
      visible: false,
    },
    compiler: {
      watOnly: false,
    },
  },
};

const scriptImportStubs = {
  callUserFunc_code_R: () => {},
  callUserFunc_string_R: () => {},
  callUserFunc_R: () => {},
  callUserFunc_i32_R: () => {},
  callUserFunc_i32_R_i32: () => {},
  callUserFunc_i32_i32_R_i32: () => {},
  callUserFunc_bool_R: () => {},
};


const Sample = (props: {
  graphInitState: Graphl.GraphInitState,
  // in order to avoid including the wasm-opt/wat2wasm, we preload the exported wasm
  wasmGetter?: (onResultHack: (res: string) => void) => Promise<WebAssembly.WebAssemblyInstantiatedSource>,
  useResultHack?: boolean,
}) => {
  const canvasRef = React.useRef<HTMLCanvasElement>(null);
  const ideRef = React.useRef<Graphl.Ide<{"main": Function}>>();

  React.useLayoutEffect(() => {
    if (canvasRef.current === null)
      throw Error("bad canvas elem");

    // TODO: use React suspense
    graphl.then(g => {
      ideRef.current = new g.Ide(canvasRef.current!, {
        ...sharedOpts,
        initState: {
          graphs: {
            main: props.graphInitState,
          },
        }
      })
    });

  }, []);

  const resultPopoverRef = React.useRef<HTMLDivElement>(null);
  const resultTimer = React.useRef<NodeJS.Timeout>();

  const flashResult = React.useCallback((result: any) => {
    const resultPopover = resultPopoverRef.current;
    if (resultPopover) {
      clearTimeout(resultTimer.current);
      resultPopover.textContent = result;
      resultPopover.style.opacity = "1.0";
      resultTimer.current = setTimeout(() => {
        resultPopover.style.opacity = "0";
      }, 5000);
    }
  }, []);

  const wasmPromise = React.useRef<Promise<WebAssembly.WebAssemblyInstantiatedSource>>();
  const getWasm = React.useCallback(() => {
    if (props.wasmGetter === undefined) return;
    if (!wasmPromise.current) {
      wasmPromise.current = props.wasmGetter(flashResult);
    }
  }, []);

  return (
    <div
      className={styles.sampleCanvas}
      style={{ position: "relative" }}
      onMouseMove={getWasm}
      // FIXME: ask Matt/Don what they think...
      title={"click the green play button to run"}
    >
      <div ref={resultPopoverRef} className={styles.canvasPopover}>
        empty result
      </div>
      <canvas
        ref={canvasRef}
        onScroll={() => false}
      />
      <div
        className={styles.execContainer}
        onClick={async () => {
          //if (props.wasmGetter === undefined) return;
          //getWasm();
          //const wasm = await wasmPromise.current!;
          //const result = wasm.instance.exports.main();
          const result = ideRef.current?.functions.main();

          if (!props.useResultHack)
            flashResult(result);
        }}
      >
        <svg height="30px" width="30px" viewBox="-3 -3 16 16">
          <path {...classNames(styles.playButton)} d="M0 0 l0 10 l10 -5 l-10 -5" />
        </svg>
      </div>
    </div>
  );
};


const Homepage = () => {
  const mediumText: React.CSSProperties = {
    fontSize: "1.5em",
    textAlign: "center",
    width: "100%",
  };

  const data = useStaticQuery(graphql`
    {
      # allFile(filter: {
      #   and: [
      #     { extension: { eq: "wasm" } },
      #     { sourceInstanceName: { eq: "graphl-samples" }}
      #   ]
      # }) {
      allFile(filter: { extension: { eq: "wasm" } }) {
        edges {
          node {
            publicURL
            name
          }
        }
      }
    }
  `)

  const sample1 = (
    <Sample
      wasmGetter={async () => {
        // FIXME: import directly instead?
        //return import("../samples/confetti.scm.wasm");
        const wasmUrl = data.allFile.edges.find(e => e.node.name === "math.scm").node.publicURL;
        return WebAssembly.instantiateStreaming(fetch(wasmUrl), {
          env: { ...scriptImportStubs, }
        });
      }}
      graphInitState={{
        notRemovable: true,
        nodes: [
          {
            id: 1,
            type: "if",
            inputs: {
              0: { node: 0, outPin: 0 },
              1: { bool: true },
            },
          },
          {
            id: 2,
            type: "+",
            inputs: {
              0: { int: 2 },
              1: { int: 3 },
            },
          },
          {
            id: 3,
            type: "return",
            inputs: {
              0: { node: 1, outPin: 0 },
              1: { node: 2, outPin: 0 },
            },
          },
          {
            id: 4,
            type: "return",
            inputs: {
              0: { node: 1, outPin: 1 },
              1: { int: 1},
            },
          },
        ],
      }
    }
    />
  );

  const sample2 = (
    <Sample
      wasmGetter={async () => {
        // FIXME: import directly instead?
        //return import("../samples/confetti.scm.wasm");
        const wasmUrl = data.allFile.edges.find(e => e.node.name === "confetti.scm").node.publicURL;
        return WebAssembly.instantiateStreaming(fetch(wasmUrl), {
          env: {
            ...scriptImportStubs,
            callUserFunc_i32_R(func_id: number, particleCount: number) {
              // assert func_id
              confetti({
                particleCount,
                spread: 70,
                origin: { y: 0.6 },
              });
            },
          }
        });
      }}
      graphInitState={{
        notRemovable: true,
        nodes: [
          {
            id: 1,
            type: "Confetti",
            inputs: {
              0: { node: 0, outPin: 0 },
              1: { int: 100 },
            },
            // FIXME: doesn't work
            position: { x: 200, y: 500 },
          },
          {
            id: 2,
            type: "return",
            inputs: {
              0: { node: 1, outPin: 0 },
            },
          },
        ],
      }}
    />
  );

  const sample3 = (
    <Sample
      useResultHack={true}
      wasmGetter={async (onResult) => {
        // FIXME: import directly instead?
        //return import("../samples/confetti.scm.wasm");
        const wasmUrl = data.allFile.edges.find(e => e.node.name === "sql.scm").node.publicURL;
        let wasm: WebAssembly.WebAssemblyInstantiatedSource;
        const wasmPromise = WebAssembly.instantiateStreaming(fetch(wasmUrl), {
          env: {
            ...scriptImportStubs,
            callUserFunc_code_R(funcId: number, codeLen: number, codePtr: number) {
              // FIXME: executing this async is bad! the memory might have changed since...
              const mem = wasm.instance.exports.memory;
              const str = new TextDecoder().decode(new Uint8Array(mem.buffer, codePtr, codeLen));
              const code = JSON.parse(str);
              onResult(sexpToSql(code));
            }
          },
        }).then((_wasm) => wasm = _wasm);
        return wasmPromise;
      }}
      graphInitState={{
        notRemovable: true,
        nodes: [
          {
            id: 2,
            type: "SELECT",
            inputs: {
              1: { string: "col1" },
            },
          },
          {
            id: 3,
            type: "FROM",
            inputs: {
              0: { node: 2, outPin: 0 },
              1: { string: "table" },
            },
          },
          {
            id: 4,
            type: "make-symbol",
            inputs: {
              0: { string: "col1" },
            },
          },
          {
            id: 5,
            type: "==",
            inputs: {
              0: { node: 4, outPin: 0 },
              1: { int: 2 },
            },
          },
          {
            id: 6,
            type: "WHERE",
            inputs: {
              0: { node: 3, outPin: 0 },
              1: { node: 5, outPin: 0 },
            },
          },
          {
            id: 1,
            type: "query-string",
            inputs: {
              0: { node: 0, outPin: 0 },
              1: { node: 6, outPin: 0 },
            },
          },
        ],
      }}
    />
  );


  // TODO: add blurbs to each canvas example
  return (
    <Layout pageTitle="Graphl" pageDesc="The next generation no-coding environment">
      <div {...classNames(styles.blurbContainer, "center-down")}>
        <div className={styles.blurbBackground} />
        {/* TODO: wrap this in a component/function to make it readable */}
        <div className={styles.bigText} style={{ fontSize: "2em", textAlign: "center" }}>
          <div style={{
            display: "flex",
            justifyContent: "center",
            alignItems: "center",
            gap: "10px",
            margin: "12px 0",
          }}>
            <Logo className={styles.logoImage} />
            <ShinyLogo className={styles["fadeInText_0"]}>
              {constants.flagshipProductName}
            </ShinyLogo>
          </div>
          <span className={styles["fadeInText_1"]}>the <em>only</em> no-code solution</span>
          <span className={styles["fadeInText_1"]}>designed to be as powerful as code</span>
        </div>

        <ShinyButton
          className={styles["fadeInText_2"]}
          style={{
            display: "flex",
            alignItems: "center",
            fontSize: "2em",
            textDecoration: "none",
            marginTop: "1em",
          }}
        >
          Try it
        </ShinyButton>

        <div className="center">
          <p style={mediumText} {...classNames(styles["fadeInText_2"])}>
            Throw away 60 years of text editing baggage and
            <br/>
            write code <strong> without writing code</strong>.
            <br/>
            Experience the programming language that feels like a <strong>workflow engine</strong>.
            <br/>
            Then export to WebAssembly and <strong>run anywhere</strong>.
          </p>
        </div>

      </div>

      <div className={styles.sampleGrid}>
          {/*
          <p style={mediumText} className={styles["fadeInText_3"]}>
            Want to understand what your AI generated?
            <br/>
            <em> Debug visually </em>
          </p>
          */}

        {/* TODO: use images instead */}
        <div className={`center ${styles.blurb}`}>
          <p style={mediumText}>
            Do all the programming stuff.
            <br />
            Math, strings, <em>if</em> this, <em>loop</em> that
            {/* add "run button" printing math result */}
          </p>
        </div>
        {sample1}

        <div className={`center ${styles.blurb}`}>
          <p style={mediumText}>
            Or embed Graphl into your own program and add custom nodes.
            <br/>
            <br/>
            On the web, call out to the host and run JavaScript from custom nodes.
            {/* add "run button" with confetti */}
          </p>
        </div>
        {sample2}

        <div className={`center ${styles.blurb}`}>
          <p style={mediumText}>
            Wield power with lisp-inspired macros, but on graphs.
            <br />
            <br />
            Visual SQL query nodes, anyone?
            {/* SQL sample */}
          </p>
        </div>
        {sample3}
      </div>

      <p style={{ textAlign: "center" }}>
        Questions?
        Reach out to us at <a href={`mailto:me@mikemikeb.com`}>support@graphl.tech</a>
      </p>

    </Layout>
  );
}

export default Homepage
