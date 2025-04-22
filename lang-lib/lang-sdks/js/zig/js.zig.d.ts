export declare interface Uint32Pair {
  upper: number; lower: number
}

export declare class Diagnostic {
  public constructor(obj: {});
  error: string;
}

export declare function compileSource(
  file_name: string,
  src: string,
  user_func_json: string,
  diagnostic: {
    error: string
  } | undefined,
): any; // FIXME: use zigar types?

