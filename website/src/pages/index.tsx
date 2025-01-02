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

// unbundled cuz stupid webpack
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

const sexpToSql = (root: any) => {
  const inner = (sexp: Sexp) => {
    if (Array.isArray(sexp)) {
      let sql = "";

      const [func, ...params] = sexp as [{symbol: string}, ...Sexp[]];

      for (let i = 0; i < params.length; ++i) {
        const param = params[i];
        if (typeof param === "object" && "symbol" in param && param.symbol in root.labels)
          params[i] = root.labels[param.symbol];
      }

      const handlePrev = () => {
        if (!Array.isArray(params[0]))
          return;
        const execParam = params.shift() as Sexp;
        const prev = inner(execParam);
        sql += prev;
        sql += '\n';
      };

      if (func.symbol === "SELECT") {
        // FIXME: this is bad
        // ignore exec entry to SELECT
        params.shift();
        params.forEach(p => { if (typeof p !== "string") throw Error(`bad SELECT arg: ${p}`); })
        sql += inner(func) + ' ' + params.join(',');

      } else if (func.symbol === "WHERE") {
        handlePrev();
        sql += inner(func) + ' ' + params.map(inner).join(',');

      } else if (func.symbol === "FROM") {
        handlePrev();
        params.forEach(p => { if (typeof p !== "string") throw Error(`bad FROM arg: ${p}`); })
        sql += inner(func) + ' ' + params.join(',');

      } else if (func.symbol === "string-equal") {
        handlePrev();
        sql += `${inner(params[0])} = ${inner(params[1])}`;

      } else if (func.symbol === "like") {
        handlePrev();
        sql += `${inner(params[0])} LIKE ${inner(params[1])}`;

      } else if (func.symbol === "==") {
        //handlePrev();
        sql += `${inner(params[0])}=${inner(params[1])}`;

      } else if (func.symbol === "make-symbol") {
        sql += params[0];

        // assume it's a binary operator
      } else {
        handlePrev();
        sql += `${inner(params[0])} ${inner(func)} ${inner(params[1])}`;

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
      throw Error(`unexpected value: ${sexp}`);
    }
  };

  return inner(root.entry)
};

let fakeReadySql = "";
let fakeReadySqlListeners = [] as ((newSql: string) => void)[];

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
  "print-query": {
    parameters: [{ name: "query", type: 5/*grappl.Types.code*/ }],
    results: [],
    impl(code) {
      // FIXME: SORRY THIS ISN'T COMPLETELY READY YET, I PROMISE IT'S WITHIN REACH
      const sql = sexpToSql(code);
      fakeReadySql = sql;
      for (const l of fakeReadySqlListeners) {
        l(fakeReadySql);
      }
      return sql;
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
  useFakeReadySql?: boolean,
  resultPopoverWidth?: string,
}) => {
  const canvasRef = React.useRef<HTMLCanvasElement>(null);
  const ideRef = React.useRef<Graphl.Ide<{"main": Function}>>();

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

  React.useLayoutEffect(() => {
    if (canvasRef.current === null)
      throw Error("bad canvas elem");

    const fakeReadySqlListener = (sql: string) => {
      flashResult(sql)
    };

    if (props.useFakeReadySql) {
      fakeReadySqlListeners.push(fakeReadySqlListener);
    }

    // TODO: use React suspense
    graphl.then(g => {
      ideRef.current = new g.Ide(canvasRef.current!, {
        ...sharedOpts,
        initState: {
          graphs: {
            main: props.graphInitState,
          },
        },
        onMainResult: (res) => {
          if (!props.useFakeReadySql) {
            flashResult(res);
          }
        },
      })
    });

    return () => {
      if (props.useFakeReadySql) {
        const listenerIndex = fakeReadySqlListeners.findIndex(l => l === fakeReadySqlListener);
        if (listenerIndex === -1) return;
        fakeReadySqlListeners.splice(listenerIndex, 1);
      }
    };
  }, []);

  const popoverWidth = props.resultPopoverWidth ?? "100px"

  return (
    <div
      className={styles.sampleCanvas}
      style={{ position: "relative" }}
      title={"click the green play button to run\nAnd try editing it!"}
    >
      <div ref={resultPopoverRef} className={styles.canvasPopover} style={{ "--width": popoverWidth }}>
        empty result
      </div>
      <canvas
        ref={canvasRef}
        onScroll={() => false}
      />
      <div
        className={styles.execContainer}
        onClick={async () => {
          ideRef.current?.functions.main();
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

  const sample1 = (
    // TODO: e2e test these, for now it's being tested with manual duplication
    // in the ide-prototype dir
    <Sample
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
      resultPopoverWidth={"300px"}
      useFakeReadySql={true}
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
            type: "print-query",
            inputs: {
              0: { node: 0, outPin: 0 },
              1: { node: 6, outPin: 0 },
            },
          },
          {
            id: 7,
            type: "return",
            inputs: {
              0: { node: 1, outPin: 0 },
              1: { int: 0 },
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
            height: "0.75em",
            paddingTop: "15px",
          }}
        >
          Try it
        </ShinyButton>

        <p style={{...mediumText, margin: "0.5em"}} {...classNames(styles["fadeInText_2"], "center")}>
          Throw away 60 years of text editing baggage and
          <br/>
          write code <strong> without writing code</strong>.
        </p>
        <p style={{...mediumText, margin: "0.5em"}} {...classNames(styles["fadeInText_2"], "center")}>
          Experience the programming language that feels like a <strong>workflow engine</strong>.
        </p>
        <p style={mediumText} {...classNames(styles["fadeInText_2"], "center")}>
          Then export to WebAssembly and <strong>run anywhere</strong>.
        </p>

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
        Reach out to us at <a href={`mailto:me@mikemikeb.com`}>me@mikemikeb.com</a>
      </p>

    </Layout>
  );
}

export default Homepage
