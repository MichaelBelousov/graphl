import React from 'react'
import Layout from '../components/layout'
import "../shared.css";
import * as styles from "./index.module.scss";
import { MailLink } from '../components/MailLink';
import * as constants from "../constants";
import { classNames } from '../react-utils';
import * as graphl from "@graphl/ide-browser";
import Logo from "../images/GraphlAnimation.inline.svg";

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
    <a href="/FIXME" {...classNames(styles.logoAnimated, className)} {...rest}>
      {btnProps.children}
    </a>
  );
};

const customNodes: Record<string, graphl.JsFunctionBinding> = {};

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
    if (canvas1Ref.current === null)
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
      },
    };

    const _ide1 = new graphl.Ide(canvas1Ref.current, {
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
    });

    const _ide2 = new graphl.Ide(canvas2Ref.current, {
      ...sharedOpts,
      initState: {
        graphs: {
          "main": {
            notRemovable: true,
            nodes: [],
          }
        },
      }
    });

    const _ide3 = new graphl.Ide(canvas3Ref.current, {
      ...sharedOpts,
      initState: {
        graphs: {
          "main": {
            notRemovable: true,
            nodes: [],
          }
        },
      }
    });


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
          <strong className={styles["fadeInText_1"]}>the <em>only</em> no-code solution</strong>
          <strong className={styles["fadeInText_1"]}>designed to be as powerful as code</strong>
        </div>

        <ShinyButton
          className={styles["fadeInText_2"]}
          style={{
            fontSize: "2em",
            textDecoration: "none",
            marginTop: "1em",
          }}
        >
          Try it
        </ShinyButton>
      </div>

      <div className={styles.sampleGrid}>
          {/*
          <p style={mediumText} className={styles["fadeInText_3"]}>
            Want to understand what your AI generated?
            <br/>
            <em> Debug visually </em>
          </p>
          */}

        <div className="center">
          <p style={mediumText} {...classNames(styles["fadeInText_2"])}>
            Throw away 60 years of text editing baggage and write code
            <em> without writing code</em>
          </p>
        </div>
        {/* TODO: use images instead */}
        <canvas
          ref={canvas1Ref}
          onScroll={e => e.stopPropagation()}
        />

        <div className="center">
          <p style={mediumText} className={styles["fadeInText_3"]}>
            Compiles to WebAssembly so you can run it anywhere,
            <br/>
            <em>including in your browser</em>
          </p>
        </div>
        <canvas
          ref={canvas2Ref}
          onScroll={() => false}
        />

        <div className="center">
          <p style={mediumText} className={styles["fadeInText_4"]}>
            Experience the programming language that feels like a
            <br/>
            <em>workflow engine</em>
          </p>

        </div>
        <canvas
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
