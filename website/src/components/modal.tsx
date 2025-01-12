import React from 'react';
import * as styles from './modal.module.scss';
import { classNames } from '../react-utils';
import { useOnExternalClick } from '@bentley/react-hooks';


const Modal = (props: React.PropsWithChildren<{
  isOpen: boolean
  setIsOpen?: (val: boolean) => void,
}>) => {
  const dialogElem = React.useRef<HTMLDialogElement>(null);

  useOnExternalClick(dialogElem, () => {
    props.setIsOpen?.(false);
  });

  React.useEffect(() => {
    const listener = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        props.setIsOpen?.(false);
      }
    };

    if (props.isOpen) {
      document.addEventListener("keyup", listener);
      return () => document.removeEventListener("keyup", listener);
    }
  }, [props.isOpen, props.setIsOpen]);

  return (
    <div
      className={styles.dialogBackground}
      style={{ display: props.isOpen ? undefined : "none" }}
    >
      <dialog ref={dialogElem} className={styles.modal} open={props.isOpen}>
        {props.children}
      </dialog>
    </div>
  );
};

export default Modal;

