import React, { useLayoutEffect, useRef, useState } from "react"
import styles from './ContextMenu.module.css'

export const ContextMenu = (props: ContextMenu.Props) => {
  const rootElem = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    const parentElement = rootElem.current?.parentElement;
    
    // FIXME: this does in fact not happen before mount first paint
    rootElem.current!.style.display = "none";

    // TODO: lodash debounce delayed close if user doesn't hover the context menu for long?

    const onRightClick = (e: MouseEvent) => {
      e.preventDefault();
      // FIXME: null or delete?
      rootElem.current!.style.top = `${e.pageY}`;
      rootElem.current!.style.left = `${e.pageX}`;
      (rootElem.current!.style as any).display = null;
    };

    const onLeftClick = (e: MouseEvent) => {
      e.preventDefault();
      const clickInContextMenu = e.currentTarget === rootElem.current
        || rootElem.current!.contains(e.currentTarget as HTMLElement);
      if (clickInContextMenu)
        return;
      rootElem.current!.style.display = "none";
    };

    parentElement?.addEventListener("contextmenu", onRightClick);
    parentElement?.addEventListener("click", onLeftClick);

    return () => {
      parentElement?.removeEventListener("contextmenu", onRightClick);
      parentElement?.removeEventListener("click", onLeftClick);
    };
  }, []);

  return <div ref={rootElem} className={styles.contextMenuRoot}>{props.children}</div>;
}

namespace ContextMenu {
  export interface Props extends React.PropsWithChildren {
  }
}

