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
  /* must match the above given results */
  impl: (...args: any[]) => any;
}

export declare namespace Ide {
  export interface Options {
    /**
     * functions which will always exist for the user,
     * and may be implemented by them
     */
    knownFunctions: Record<string, {}>,
    bindings: {
      jsHost: {
        functions: Record<string, JsFunctionBinding>;
      }
    }
  }
}

