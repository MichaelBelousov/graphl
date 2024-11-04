declare module '*.svg' {
  const path: string
  const ReactComponent: string
  export default path
  export { ReactComponent }
}

declare module '*.module.scss' {
  const classes: Record<string, string>
  export default classes
}

declare module '*.module.css' {
  const classes: Record<string, string>
  export default classes
}

declare module '*.css'
declare module '*.scss'
