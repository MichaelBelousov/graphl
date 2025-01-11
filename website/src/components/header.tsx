import { Link } from 'gatsby';
import React from 'react';
import ReactDOM from 'react-dom';
import * as styles from './header.module.scss';
import Logo from '../images/GraphlAnimation.inline.svg';
import { useIsMobileLike } from '../useIsMobileLike';
import * as constants from "../constants";
import { classNames } from '../react-utils';
import Modal from '../components/modal'

let subscribeContainer: HTMLDivElement | undefined = undefined;

if (typeof document !== "undefined") {
  subscribeContainer = document.createElement("div");
  document.body.append(subscribeContainer);
}

const Header = () => {
  const [subscribeOpen, setSubscribeOpen] = React.useState(false);

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
      <a
        {...classNames(styles.navLink, styles.subButton)}
        onClick={() => {
          setSubscribeOpen(prev => !prev);
        }}>
        subscribe
      </a>
    </nav>
  );

  // FIXME: this isn't SSRable, so just do it all in CSS
  const isMobileLike = useIsMobileLike();

  const [emailInput, setEmailInput] = React.useState("");

  const emailInputRef = React.useRef<HTMLInputElement>(null);

  React.useEffect(() => {
    if (emailInputRef.current && subscribeOpen) {
      emailInputRef.current.focus();
    }
  }, [subscribeOpen])

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
      {
      subscribeContainer && ReactDOM.createPortal(
        <Modal isOpen={subscribeOpen} setIsOpen={setSubscribeOpen}>
          <form
            className={styles.subscribeModalContent}
            action={`https://docs.google.com/forms/d/e/1FAIpQLSdIbJ7Ye-J5fdLjuLjSIqx6B7YKTQJfI8jk3gNTIc4CVw9ysg/formResponse?submit=Submit&usp=pp_url&entry.633639765=${emailInput}&entry.522288266=nofeedback`}
            method="POST"
            target="hidden-target-frame"
            onSubmit={(_e) => {
              // TODO: check if successful!
              setSubscribeOpen(false);
            }}
          >
            Subscribe!
            <input
              className={styles.subInput}
              ref={emailInputRef}
              value={emailInput}
              onChange={e => setEmailInput(e.currentTarget.value)}
              placeholder="you@example.com"
              type="email"
            />
            <input value="subscribe" className={styles.subButton} type="submit"></input>
            <iframe style={{ display: "none" }} name="hidden-target-frame" />
          </form>
        </Modal>,
        subscribeContainer
      )}
    </header>
  );
};

export default Header;

