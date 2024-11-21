import React from 'react'
import Layout from '../components/layout'
import "../shared.css";
import * as styles from "./index.module.scss";
import { MailLink } from '../components/MailLink';
import * as constants from "../constants";
import { classNames } from '../react-utils';
import * as graphl from "@graphl/ide-browser";

const ShinyLogo = (divProps: React.HTMLProps<HTMLDivElement>) => {
  const {className, ...rest} = divProps;
  return (
    <h1 {...classNames(styles.logoAnimated, className)} {...rest}>
      {constants.flagshipProductName}
    </h1>
  );
};

const customNodes: Record<string, graphl.JsFunctionBinding> = {};

const Homepage = () => {
  const mediumText: React.CSSProperties = {
    fontSize: "1.5em",
    textAlign: "center",
    width: "100%",
  };

  const canvasRef = React.useRef<HTMLCanvasElement>(null);

  React.useLayoutEffect(() => {
    if (canvasRef.current === null)
      throw Error("bad canvas elem");

    const _ide = new graphl.Ide(canvasRef.current, {
      bindings: {
        jsHost: {
          functions: customNodes,
        }
      },
      preferences: {
        definitionsPanel:  {
          visible: false,
        },
        topbar: {
          visible: false,
        }
      },
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
  }, []);

  return (
    <Layout pageTitle="Graphl" pageDesc="The next generation no-coding environment">
      <div style={{position: "relative"}}>
        <div className={styles.blurbBackground} />
        {/* TODO: wrap this in a component/function to make it readable */}
        <div className={styles.bigText} style={{ fontSize: "2em", textAlign: "center" }}>
          <ShinyLogo className={styles["fadeInText_0"]} style={{ marginBottom: "0.5em" }} />
          <br/>
          <strong className={styles["fadeInText_1"]}>is the <em>only</em> no-code solution</strong>
          {" "}
          <strong className={styles["fadeInText_1"]}>that is as powerful as code</strong>
        </div>

        <div>
          <br/>
          {/* TODO: need an image! */}
          <p style={mediumText} {...classNames(styles["fadeInText_2"])}>
            Throw away 60 years of text editing baggage and write code
            <br/>
            <em> without writing code</em>
          </p>

          {/*
          <p style={mediumText} className={styles["fadeInText_3"]}>
            Want to understand what your AI generated?
            <br/>
            <em> Debug visually </em>
          </p>
          */}

          <p style={mediumText} className={styles["fadeInText_3"]}>
            Compile to WebAssembly and run anywhere,
            <br/>
            <em> even in your browser </em>
          </p>

          <p style={mediumText} className={styles["fadeInText_4"]}>
            Experience the programming language that feels like a
            <br/>
            <em>workflow engine</em>
          </p>

          <br/>
          <p style={{ textAlign: "center" }}>
            Questions?
            Reach out to us at <a href={`mailto:me@mikemikeb.com`}>support@graphl.tech</a>
          </p>
        </div>
      </div>

      <canvas
        ref={canvasRef}
        style={{
          width: "100%",
          height: "auto",
          border: 0,
          margin: "30px 0",
          pointerEvents: "none",
        }}
      />

    </Layout>
  );
}

export default Homepage
