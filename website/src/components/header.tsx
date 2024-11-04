import { Link } from 'gatsby';
import React from 'react';
import * as styles from './header.module.scss';
import logoPath from '../images/logo2.svg';
import { useIsMobileLike } from '../useIsMobileLike';
import * as constants from "../constants";

const Header = () => {
  const logo = (
    <div className={styles.left}>
      {/* FIXME: make svg logo */}
      <Link className={`${styles.navLink} ${styles.logo}`} to="/">
        <img src={logoPath} width="80px" /> {constants.companyName}
      </Link>
    </div>
  );

  const links = (
    <nav className={styles.right}>
      <a className={styles.navLink}
        href={process.env.NODE_ENV === "development" ? "http://localhost:3001/app/#?trial" : "/app/#?trial"}
      >
        Try it
      </a>
      <Link className={styles.navLink} to="/pricing">Pricing</Link>
      <Link className={styles.navLink} to="/blog">Blog</Link>
    </nav>
  );

  // FIXME: this isn't SSRable, so just do it all in CSS
  const isMobileLike = useIsMobileLike();

  // FIXME: place the links differently on mobile, keep them!
  return (
    <header>
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

