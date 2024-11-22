import { Link } from 'gatsby';
import React from 'react';
import * as styles from './header.module.scss';
import Logo from '../images/GraphlAnimation.inline.svg';
import { useIsMobileLike } from '../useIsMobileLike';
import * as constants from "../constants";
import { classNames } from '../react-utils';

const Header = () => {
  const logo = (
    <div className={styles.left}>
      {/* FIXME: make svg logo */}
      <Link className={`${styles.navLink} ${styles.logo}`} to="/">
        <Logo height="1.5em" width="1.5em" /> {constants.flagshipProductName}
      </Link>
    </div>
  );

  const links = (
    <nav className={styles.right}>
      <Link className={styles.navLink} to="/app">try it</Link>
      <Link className={styles.navLink} to="/faqs">FAQs</Link>
      <Link className={styles.navLink} to="/commercial">commercial</Link>
      {/* TODO: blog <Link className={styles.navLink} to="/blog/HowICameUpWithGraphl">blog</Link>*/}
      <Link className={styles.navLink} to="/blog/docs">docs</Link>
      <Link {...classNames(styles.navLink, styles.subButton)} to="/FIXME">subscribe</Link>
    </nav>
  );

  // FIXME: this isn't SSRable, so just do it all in CSS
  const isMobileLike = useIsMobileLike();

  // FIXME: place the links differently on mobile, keep them!
  return (
    <header style={{ borderBottom: "1px solid rgba(var(--body-rgb), 0.2)"}}>
      {!isMobileLike ? (
        <div className={styles.separate}>
          {logo} {links}
        </div>
      ) : (
        <div className={"center"} style={{ paddingTop: "50px"}}>
          {logo}
        </div>
      )}
    </header>
  );
};

export default Header;

