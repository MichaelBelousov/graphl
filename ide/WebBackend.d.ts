// TODO: type check with this file isn't working

import { GraphlProgram } from "@graphl/compiler-js";

/** @see {./src/web-app.zig} */

type AnyFuncs = Record<string, (...args: any[]) => any>;

export declare interface Ide<Funcs extends AnyFuncs> {
  compile(): Promise<GraphlProgram<Funcs>>;
  exportWasm(): Promise<Uint8Array>;
  exportGraphlt(): Promise<string>;
}

export declare function Ide<Funcs extends AnyFuncs>(
  canvas: HTMLCanvasElement,
  opts?: Ide.Options
): Promise<Ide<Funcs>>;

export declare type PrimitiveType =
  | "u64"
  | "u32"
  | "i32"
  | "i64"
  | "f32"
  | "f64"
  | "string"
  | "code"
  | "bool"
  | "rgba"
  | "vec3"
;

export declare type Type = PrimitiveType;

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
  /** optional position */
  position?: { x: number, y: number };
}

// FIXME: add hidden to this so fixedSignature graphs can't be called
export declare interface GraphInitState {
  /**
   * Disallow editing of the parameter or result types,
   * and disallow removing.
   * @default false
   */
  fixedSignature?: boolean,
  /** the entry node will always added (since it is required) */
  nodes?: NodeInitState[],
  /** @default empty */
  inputs?: PinJson[];
  /** @default empty */
  outputs?: PinJson[];
}

export declare interface PinJson {
  name: string;
  type: PrimitiveType;
}

export declare interface BasicMutNodeDescJson {
  //name?: string; // derived from outer object
  hidden?: boolean;
  /**
   * "func" means it requires control flow and has in and out exec pins
   * "pure" means it has no exec pins and should not have side effects
   * @default "func"
   */
  kind?: "func" | "pure",
  inputs?: PinJson[];
  outputs?: PinJson[];
  tags?: string[];
  /*
   * if defined, must match the above given inputs/outputs
   * if undefined, this is a data-only node.
   * Use `multiresult` to return multiple results
   */
  impl?: (...args: any[]) => any;
}

export declare type UserFuncJson = BasicMutNodeDescJson & {
  // FIXME: patched in by WebBackend.js
  id?: number;
}

export declare interface MenuOption {
  name: string;
  onClick?: () => any;
  submenus?: MenuOption[];
}

export declare namespace Ide {
  export interface Options {
    menus?: MenuOption[];
    // TODO: rename
    userFuncs?: Record<string, UserFuncJson>;
    allowRunning?: boolean,
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
        /**
         * if true, do not include the "Build" menu with its run options.
         * overridden to true if "allowRunning" is set to false
         */
        noDefaultMenus?: boolean;
      },
      definitionsPanel?:  {
        /** where to place the side panel */
        orientation?: "left", // TODO: add "right"
        /** whether or not the side panel is visible */
        visible?: boolean;
      },
      compiler?: {
        /**
         * @default false
         * prevents fetching the wasm-opt binary which saves 10MB bandwidth
         * but prevents execution of compiled code
         *
         * this is a temporary measure for display-only scenarios
         */
        // TODO: remove? doesn't exist as an option atm
        // watOnly?: boolean;
      };
    },
    /**
     * initial state of the IDE, e.g. which graphs exist
     * mark graphs as non-removable here
     */
    graphs?: Record<string, GraphInitState>;
    /** a callback with the result for when the main graph function had a run triggered by the user */
    onMainResult?(result: any): void;
  }
}

declare class MultiResult {
  results: any[]
}

export declare function multiresult(array: any[]): MultiResult;
