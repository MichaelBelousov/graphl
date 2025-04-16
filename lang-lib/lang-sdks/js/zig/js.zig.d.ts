export declare interface Uint32Pair {
  upper: number; lower: number
}

export declare function compileSource(
  file_name: string,
  src: string,
  diagnostic: {
    error: string
  } | undefined,
): any; // FIXME: use zigar types?

