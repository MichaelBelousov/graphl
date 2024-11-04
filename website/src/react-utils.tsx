/** Utilities for JSX (and apparently react too) */

import * as React from "react";

/**
 * use like
 * @example
 * <div {...classNames("a", c && "d")} />
 */
export const classNames = (...cx: any[]) =>
  ({ className: cx.filter(Boolean).map(String).join(" ") });

export const makeInaccessibleObject = <T extends object>(message: string) => new Proxy({} as T, {
  get() {
    throw Error(`Attempted to get a field on an inaccessible object: ${message}`);
  }
})

// FIXME: move to non-react utils
export function deepCloneJson<T>(t: T): T {
  return JSON.parse(JSON.stringify(t));
}

export function useForceUpdate() {
  const [, _setFakeState] = React.useState(0);
  return React.useRef(() => _setFakeState(p => p + 1)).current;
}

/**
 * Returns html props that can be put on an HTML element, and will
 * call a callback (after a delay) upon no longer being interacted with
 */
export function useOnNoLongerMouseInteracted({
  /**
   * the amount of time with mouse outside the element to consider
   * it no longer interacted with
   */
  delayMs = 1_000,
  /** what to do when the element is considered no longer interacted with */
  onUninterested = () => {},
} = {}) {
  let timeout: NodeJS.Timeout | undefined;

  const onUninterestedRef = React.useRef(onUninterested);
  onUninterestedRef.current = onUninterested;

  const _onUninterested = () => {
    timeout = setTimeout(() => onUninterestedRef.current(), delayMs);
  };

  // do on mount
  React.useEffect(() => void _onUninterested(), []);

  return React.useRef({
    props: {
      onMouseMove: () => {
        if (timeout) clearTimeout(timeout);
        timeout = undefined;
      },
      onMouseEnter: (e: React.MouseEvent) => {
        e.preventDefault();
        if (timeout) clearTimeout(timeout);
        timeout = undefined;
      },
      onMouseLeave: (e: React.MouseEvent) => {
        e.preventDefault();
        _onUninterested();
      },
    },
    forceInterest() {
      this.props.onMouseLeave({ preventDefault: () => {} } as React.MouseEvent);
    }
  }).current;
}

