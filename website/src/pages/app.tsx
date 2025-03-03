import React from 'react'
import "../shared.css";
import * as graphl from "@graphl/ide";
import SEO from '../components/seo';
import "./app.css";
import { confetti } from "@tsparticles/confetti";

const customNodes: Record<string, graphl.UserFuncJson> = {
  /*
  fetch: {
    // TODO: optional nodes
    // TODO: make this a (starting) import
    parameters: [
      { name: "url", type: graphl.Types.string },
      // TODO: this is what enum types are for!
      { name: "method", type: graphl.Types.string },
    ],
    results: [
      { name: "status", type: graphl.Types.i32 },
      { name: "data", type: graphl.Types.string },
    ],
    // TODO: need to be able to handle async nodes
    async impl(url, method) {
      const data = await fetch(url, { method });
      const text = await data.text();
      return text;
    }
  },
  */
  "Confetti": {
    inputs: [{ name: "particle count", type: "i32" }],
    outputs: [],
    impl(particleCount: number) {
      confetti({
        particleCount,
        spread: 70,
        origin: { y: 0.6 },
      });
    }
  },
};

const Homepage = () => {
  // use images, this many IDEs is horrible for memory usage...
  const canvasRef = React.useRef<HTMLCanvasElement>(null);

  React.useLayoutEffect(() => {
    document.body.style.overflow = "hidden";
    if (canvasRef.current === null)
      throw Error("bad canvas elem");

    const _ide = new graphl.Ide(canvasRef.current, {
      userFuncs: customNodes,
      graphs: {
        "main": {
          fixedSignature: true,
          outputs: [{
            name: "result",
            type: "i32",
          }],
          nodes: [
            {
              id: 1,
              type: "Confetti",
              inputs: {
                0: { node: 0, outPin: 0 },
                1: { int: 100 },
              },
            },
            {
              id: 2,
              type: "return",
              inputs: {
                0: { node: 1, outPin: 0 },
              },
            },
          ],
        },
      }
    });

    return () => { document.body.style.overflow = "initial"; };
  }, []);


  // TODO: add blurbs to each canvas example
  return (
    <div style={{ overflow: "hidden", margin: 0, padding: 0 }}>
      <SEO title={"Graphl Web IDE"} description={"Use Graphl on the web"} />
      <canvas
        ref={canvasRef}
        style={{
          width: "100vw",
          height: "100vh",
        }}
      />
    </div>
  );
}

export default Homepage
