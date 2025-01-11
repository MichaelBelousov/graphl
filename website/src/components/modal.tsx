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

