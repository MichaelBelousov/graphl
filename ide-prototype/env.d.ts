
declare module "*.module.css" {
  const styles = Record<string, string>
  export default styles
}

// TODO: use vite types

declare module "*.wasm?init" {
  export default function(): Promise<WebAssembly.Instance>;
}
