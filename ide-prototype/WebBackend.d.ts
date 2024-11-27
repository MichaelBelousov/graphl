// TODO: type check with this file isn't working

export declare class Ide {
  public constructor(canvas: HTMLCanvasElement, opts?: Ide.Options)
}

export declare const Types: {
  "i32": 0,
  "i64": 1,
  "f32": 2,
  "f64": 3,
  "string": 4,
  "code": 5,
  "bool": 6,
};

export declare type PrimitiveType = typeof Types[keyof typeof Types];
export declare type Type = PrimitiveType;

export declare interface BindingDesc {
  name: string;
  type: PrimitiveType;
}

// TODO: offer a fully typed interface
export declare interface JsFunctionBinding {
  //name: string;
  parameters: BindingDesc[];
  results: BindingDesc[];
  /*
   * if defined, must match the above given parameters/results
   * if undefined, this is a data-only node
   */
  impl?: (...args: any[]) => any;
}

export declare type InputInitState =
  | { node: number, outPin: number }
  | { int: number }
  | { float: number }
  | { string: string }
  | { bool: boolean }
  | { symbol: string };

export declare interface NodeInitState {
  /** id of the node, must be positive and non-zero which is reserved for the graph entry node */
  id: number;
  /** type of node, e.g. "+" */
  type: string;
  /** inputs */
  inputs?: Record<number, InputInitState>,
}

export declare interface GraphInitState {
  /** @default false */
  notRemovable?: boolean,
  /** @default just the entry node (since it is required) */
  nodes?: NodeInitState[],
}

export declare interface InitState {
  graphs: Record<string, GraphInitState>;
}

export declare namespace Ide {
  export interface Options {
    /**
     * functions which will always exist for the user,
     * and may be implemented by them
     */
    knownFunctions?: Record<string, {}>,
    bindings?: {
      jsHost?: {
        functions?: Record<string, JsFunctionBinding>;
      }
    },
    /** initial preferences for the IDE */
    preferences?: {
      graph?: {
        origin?: { x: number, y: number };
        scale?: number;
        scrollBarsVisible?: boolean;
        allowPanning?: boolean;
      },
      topbar?: {
        visible?: boolean,
      },
      definitionsPanel?:  {
        /** where to place the side panel */
        orientation?: "left", // TODO: add "right"
        /** whether or not the side panel is visible */
        visible?: boolean;
      },
      compiler: {
        /**
         * @default false
         * prevents fetching the wasm-opt binary which saves 10MB bandwidth
         * but prevents execution of compiled code
         *
         * this is a temporary measure for display-only scenarios
         */
        watOnly: boolean;
      };
    },
    /**
     * initial state of the IDE, e.g. which graphs exist
     * mark graphs as non-removable here
     */
    initState?: InitState;
  }
}

