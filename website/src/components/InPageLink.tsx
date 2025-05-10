import React from 'react'
import "../shared.css";
import { classNames } from '../react-utils';

export const InPageLink = (props: { slug: string } & React.HTMLProps<HTMLAnchorElement> & React.PropsWithChildren<{}>) => {
  return (
    <a
      {...props}
      href={`#${props.slug}`}
      id={props.slug}
      {...classNames("in-page-link", props.className)}
    >
      {props.children}
    </a>
  );
};
