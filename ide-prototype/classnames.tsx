
export function classNames(...args: (string | false | 0 | null | undefined)[]) {
  return args.filter(Boolean).join(' ')
}

export default classNames

