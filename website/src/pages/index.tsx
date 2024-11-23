import React from 'react'
import Layout from '../components/layout'
import "../shared.css";
import * as styles from "./index.module.scss";
import { MailLink } from '../components/MailLink';
import * as constants from "../constants";
import { classNames } from '../react-utils';
import type * as Graphl from "@graphl/ide-browser";
import Logo from "../images/GraphlAnimation.inline.svg";

const graphl = import("@graphl/ide-browser");

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

const customNodes: Record<string, Graphl.JsFunctionBinding> = {};

const Homepage = () => {
  const mediumText: React.CSSProperties = {
    fontSize: "1.5em",
    textAlign: "center",
    width: "100%",
  };

  // use images, this many IDEs is horrible for memory usage...
  const canvas1Ref = React.useRef<HTMLCanvasElement>(null);
  const canvas2Ref = React.useRef<HTMLCanvasElement>(null);
  const canvas3Ref = React.useRef<HTMLCanvasElement>(null);

  React.useLayoutEffect(() => {
    if (!(canvas1Ref.current !== null && canvas2Ref.current !== null && canvas3Ref.current !== null))
      throw Error("bad canvas elem");

    const sharedOpts = {
      bindings: {
        jsHost: {
          functions: customNodes,
        },
      },
      preferences: {
        graph: {
          scrollBarsVisible: false,
          origin: { x: 200, y: 200 },
        },
        definitionsPanel:  {
          visible: false,
        },
        topbar: {
          visible: false,
        },
        compiler: {
          watOnly: true,
        },
      },
    };

    // TODO: use React suspense
    const _ide1 = graphl.then(g => new g.Ide(canvas1Ref.current!, {
      ...sharedOpts,
      initState: {
        graphs: {
          "main": {
            notRemovable: true,
            nodes: [
              {
                id: 1,
                type: "return",
                inputs: {
                  0: { node: 2, outPin: 0 },
                },
              },
              {
                id: 2,
                type: "+",
                inputs: {
                  0: { float: 1.0 },
                  1: { float: 2.0 },
                },
              },
            ],
          }
        },
      }
    }));

    const _ide2 = graphl.then(g => new g.Ide(canvas2Ref.current!, {
      ...sharedOpts,
      initState: {
        graphs: {
          "main": {
            notRemovable: true,
            nodes: [],
          }
        },
      }
    }));

    const _ide3 = graphl.then(g => new g.Ide(canvas3Ref.current!, {
      ...sharedOpts,
      initState: {
        graphs: {
          "main": {
            notRemovable: true,
            nodes: [],
          }
        },
      }
    }));


  }, []);

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
        <div className="center">
          <p style={mediumText}>
            Do all the programming stuff.
            <br />
            Math, strings, <em>if</em> this, <em>loop</em> that
            {/* add "run button" printing math result */}
          </p>
        </div>
        <canvas
          className={styles.sampleCanvas}
          ref={canvas1Ref}
          onScroll={e => e.stopPropagation()}
        />

        <div className="center">
          <p style={mediumText}>
            Or embed Graphl into your own program and add custom nodes.
            <br/>
            <br/>
            On the web, call out to the host and run JavaScript from custom nodes.
            {/* add "run button" with confetti */}
          </p>
        </div>
        <canvas
          className={styles.sampleCanvas}
          ref={canvas2Ref}
          onScroll={() => false}
        />

        <div className="center">
          <p style={mediumText}>
            Wield power with lisp-inspired macros but on graphs.
            <br />
            <br />
            Visual SQL query macros, anyone?
            {/* SQL sample */}
          </p>
        </div>
        <canvas
          className={styles.sampleCanvas}
          ref={canvas3Ref}
          onScroll={() => false}
        />
      </div>

      <p style={{ textAlign: "center" }}>
        Questions?
        Reach out to us at <a href={`mailto:me@mikemikeb.com`}>support@graphl.tech</a>
      </p>

    </Layout>
  );
}

export default Homepage
