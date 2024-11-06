
export declare class Ide {
  public constructor(canvas: HTMLCanvasElement, opts?: Ide.Options)
}

export declare interface TypeDesc {
  name: string;
}

export declare interface BindingDesc {
  name: string;
  type: TypeDesc;
}

// TODO: offer a fully typed interface
export declare interface JsFunctionBinding {
  //name: string;
  parameters: BindingDesc[];
  results: BindingDesc[];
  impl: (t: any) => any;
}

export declare namespace Ide {
  export interface Options {
    bindings: {
      jsHost: {
        functions: Record<string, JsFunctionBinding>;
      }
    }
  }
}

