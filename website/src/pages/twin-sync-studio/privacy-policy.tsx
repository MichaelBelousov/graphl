import React from 'react'
import Layout from '../../components/layout'
import "../../shared.css";
import "./privacy-policy.css";
import { InPageLink } from "../../components/InPageLink";

const PrivacyPolicy = () => {
  return (
    <div className="itue-doc-root">
      <h1>Graphl Technologies Privacy Policy</h1>

      Effective Date: May 10, 2025

      Applicable To The Following services:

      <ul>
        <li>Twin Sync Studio desktop application and accompanying services (for example, web services for evaluating product validity)</li>
        <li>Graphl Technologies Website</li>
      </ul>

      <section>
        <h3>Article 1 - DEFINITIONS:</h3>
        <ol style={{ listStyle: "lower-alpha" }}>
          <li> APPLICABLE SERVICES: This Privacy Policy will refer to and be applicable to the
            applicable services listed above, which shall hereinafter be referred to as "Applicable Services."
          </li>
          <li> EFFECTIVE DATE: "Effective Date" means the date this Privacy Policy comes into
            force and effect.
          </li>
          <li> PARTIES: The parties to this privacy policy are the following data controller:
            Graphl Technologies LLC ("Data Controller") and you, as the user of these Applicable Services. Hereinafter, the
            parties will individually be referred to as "Party" and collectively as "Parties."
          </li>
          <li> DATA CONTROLLER: Data Controller is the publisher, owner, and operator of the
            services and is the Party responsible for the collection of information described herein.
            Data Controller shall be referred to either by Data Controller's name or "Data Controller,"
            as listed above. If Data Controller or Data Controller's property shall be referred to
            through first-person pronouns, it shall be through the use of the following: us, we, our,
            ours, etc.
          </li>
          <li> YOU: Should you agree to this Privacy Policy and continue your use of the Applicable Services,
            you will be referred to herein as either you, the user, or if any second-person pronouns
            are required and applicable, such pronouns as 'your", "yours", etc.
          </li>
          <li>
            GOODS: "Goods" means any goods that we make available for sale on the Graphl Technologies Website.
          </li>
          <li>  PERSONAL DATA: "Personal Data" means personal data and information that we
            obtain from you in connection with your use of the Applicable Services that is capable of identifying
            you in any manner.
          </li>
        </ol>
      </section>

      <section>
        <h3>Article 2 - GENERAL INFORMATION:</h3>
        This privacy policy (hereinafter "Privacy Policy") describes how we collect and use the
        Personal Data that we receive about you, as well as your rights in relation to that
        Personal Data, when you use our Applicable Services or purchase our Goods.
        This Privacy Policy does not cover any information that we may receive about you
        through sources other than the use of our Applicable Services. The Applicable Services
        may link out to other websites or mobile applications, but this Privacy Policy does not
        and will not apply to any of those linked websites or applications.
        We are committed to the protection of your privacy while you use our Applicable Services.
        By continuing to use our Applicable Services, you acknowledge that you have had the chance to
        review and consider this Privacy Policy, and you acknowledge that you agree to it. This
        means that you also consent to the use of your information and the method of disclosure
        as described in this Privacy Policy. If you do not understand the Privacy Policy or do not
        agree to it, then you agree to immediately cease your use of our Applicable Services.
      </section>


      <section>
        <h3> Article 3 -CONTACT AND DATA PROTECTION OFFICER: </h3>
        The Party responsible for the processing of your personal data is as follows: Graphl Technologies LLC.
        The Data Controller may be contacted as follows: <a href="mailto:mike@graphl.tech">mike@graphl.tech</a>
        <br />
        The Data Controller and operator of the Applicable Services are one and the same.
        <br />
        The Data Protection Officer is as follows: Michael Belousov.
        <br/>
        The Data Protection Officer may be contacted as follows: <a href="mailto:mike@graphl.tech">mike@graphl.tech</a>
      </section>
      <section>
        <h3> Article 4 - LOCATION: </h3>
        Please be advised the data processing activities take place in the United States, outside
        the European Economic Area. Data may also be transferred to companies within the
        United States, but will only be done so in a manner that complies with the EU's General
        Data Protection Regulation or GDPR. The location where the data processing activities
        take place is as follows:
        <br />
        North Carolina, United State of America.
      </section>

      <section>
        <h3>
          Article 5 - MODIFICATIONS AND REVISIONS:
        </h3>
        We reserve the right to modify, revise, or otherwise amend this Privacy Policy at any
        time and in any manner. If we do so, however, we will notify you and obtain your consent
        to the change in processing. Unless we specifically obtain your consent, any changes to
        the Privacy Policy will only impact the information collected on or after the date of the
        change. It is also your responsibility to periodically check this page for any such
        modification, revision or amendment.
      </section>

      <section>
        <h3> Article 6 - THE PERSONAL DATA WE RECEIVE FROM YOU: </h3>
        Depending on how you use our Applicable Services, you will be subject to different types of
        Personal Data collected and different manners of collection:
        <ul style={{listStyle: "lower-alpha"}}>
          {/* <li> */}
          {/*   <strong>Registered users:</strong> You, as a user of the Website, may be asked to register in */}
          {/*   order to use the Website or to purchase the Goods available for sale. */}
          {/*   During the process of your registration, we will collect some of the following */}
          {/*   Personal Data from you through your voluntary disclosure: */}
          {/*   ________ */}
          {/*   Personal Data may be asked for in relation to: */}
          {/*   <ul style={{listStyle: "upper-roman"}}> */}
          {/*     <li> Interaction with our representatives in any way </li> */}
          {/*     <li> making purchases </li> */}
          {/*     <li> receiving notifications by text message or email about marketing </li> */}
          {/*     <li> receiving general emails from us </li> */}
          {/*     <li> commenting on our content or other user-generated content on our Website, */}
          {/*       such as blogs, articles, photographs or videos, or participating in our forums, */}
          {/*       bulletin boards, chat rooms or other similar features */}
          {/*     </li> */}
          {/*   </ul> */}

          {/*   By undergoing the registration process, you consent to us collecting your Personal */}
          {/*   Data, including the Personal Data described in this clause, as well as storing, using */}
          {/*   or disclosing your Personal Data in accordance with this Privacy Policy. */}
          {/* </li> */}

          <li><strong>All users:</strong> If you are a user of the  services, and do not register
            for any purchases or other service, you may still be subject to certain passive data
            collection ("Passive Data Collection"). Such Passive Data Collection may include
            IP address information, location information, and certain browser data, such as history and/or session information.
          </li>
          <li>
            <strong>All users:</strong> The Passive Data Collection that applies to Unregistered users shall
            also apply to all other users and/or visitors of our Applicable Services.
          </li>
          <li>
            <strong>Sales &amp; Billing Information:</strong> In order to purchase any of the goods on the
            Graphl Technologies Website, a third-party <a href="https://stripe.com/">Stripe, Inc.</a>, will
            be used to securely process your credit and billing information. They may store or charge such
            information of yours on our behalf, with your consent and only as we have specified.
            Please refer to <a href="https://stripe.com/privacy">their privacy policy</a> for further details
            when purchasing our Goods.
          </li>
          <li>
            <strong>Related Entities:</strong> We may share your Personal Data, including Personal Data
            that identifies you personally, with any of our parent companies, subsidiary
            companies, affiliates or other trusted related entities.
            However, we only share your Personal Data with a trusted related entity if that entity
            agrees to our privacy standards as set out in this Privacy Policy and to treat your
            Personal Data in the same manner that we do.
            <br/>
            As of now, no entities fit this criteria.
          </li>
          <li>
            <strong>Email Marketing:</strong> You may be asked to provide certain Personal Data, such as
            your name and email address, for the purpose of receiving email marketing
            communications. This information will only be obtained through your voluntary
            disclosure and you will be asked to affirmatively opt-in to email marketing
            communications.
          </li>
          <li>
            <strong>User Experience:</strong> From time to time we may request information from you to
            assist us in improving our Applicable Services, and the Goods we sell, such as demographic
            information or your particular preferences.
          </li>
          {/* <li> */}
          {/*   <strong>Content Interaction:</strong> Our Applicable Services may allow you to comment on the content that */}
          {/*   we provide or the content that other users provide, such as blogs, multimedia, or */}
          {/*   forum posts. If so, we may collect some Personal Data from you at that time, such */}
          {/*   as, but not limited to, username or email address. */}
          {/* </li> */}
          <li>
            <strong>Combined or Aggregated Information:</strong> We may combine or aggregate some of
            your Personal Data in order to better serve you and to better enhance and update
            our Applicable Services for your and other consumers' use.
            We may also share such aggregated information with others, but only if that
            aggregated information does not contain any Personal Data.
          </li>
        </ul>

      </section>
      <section>
        <strong>Cookies:</strong> At this time, for your privacy and security, we do not include any cookies in any of the Applicable Services.
        This does not however account for integrations with a third-party, such as the iTwin integration of Twin Sync Studio.
        It will be made clear that you are integrating with a third-party when that is the case.
        <br/>
        In the case of iTwin, refer to their <a href="https://www.bentley.com/legal/privacy-policy/">privacy policy</a> for
        more information, when using the integration of their service in our Applicable Services.

        {/* We may collect information from you through automatic tracking systems */}
        {/* (such as information about your browsing preferences) as well as through information */}
        {/* that you volunteer to us (such as information that you provide during a registration */}
        {/* process or at other times while using the Website, as described above). */}
        {/* For example, we use cookies to make your browsing experience easier and more */}
        {/* intuitive: cookies are small strings of text used to store some information that may */}
        {/* concern the user, his or her preferences or the device they are using to access the */}
        {/* internet (such as a computer, tablet, or mobile phone). Cookies are mainly used to adapt */}
        {/* the operation of the site to your expectations, offering a more personalized browsing */}
        {/* experience and memorizing the choices you made previously. */}
        {/* A cookie consists of a reduced set of data transferred to your browser from a web server */}
        {/* and it can only be read by the server that made the transfer. This is not executable code */}
        {/* and does not transmit viruses. */}
        {/* Cookies do not record or store any Personal Data. If you want, you can prevent the use */}
        {/* of cookies, but then you may not be able to use our Website as we intend. To proceed */}
        {/* without changing the options related to cookies, simply continue to use our Website. */}
        {/* Technical cookies: Technical cookies, which can also sometimes be called HTML */}
        {/* cookies, are used for navigation and to facilitate your access to and use of the site. */}
        {/* They are necessary for the transmission of communications on the network or to */}
        {/* supply services requested by you. The use of technical cookies allows the safe and */}
        {/* efficient use of the site. */}
        {/* You can manage or request the general deactivation or cancelation of cookies */}
        {/* through your browser. If you do this though, please be advised this action might */}
        {/* slow down or prevent access to some parts of the site. */}
        {/* Cookies may also be retransmitted by an analytics or statistics provider to collect */}
        {/* aggregated information on the number of users and how they visit the Website. */}
        {/* These are also considered technical cookies when they operate as described. */}
        {/* Temporary session cookies are deleted automatically at the end of the browsing */}
        {/* session - these are mostly used to identify you and ensure that you don't have to log */}
        {/* in each time - whereas permanent cookies remain active longer than just one */}
        {/* particular session. */}
        {/* Third-party cookies: We may also utilize third-party cookies, which are cookies */}
        {/* sent by a third-party to your computer. Permanent cookies are often third-party */}
        {/* cookies. The majority of third-party cookies consist of tracking cookies used to */}
        {/* identify online behavior, understand interests and then customize advertising for */}
        {/* users. */}
        {/* Third-party analytical cookies may also be installed. They are sent from the domains */}
        {/* of the aforementioned third parties external to the site. Third-party analytical cookies */}
        {/* are used to detect information on user behavior on our Website. This place */}
        {/* anonymously, in order to monitor the performance and improve the usability of the */}
        {/* site. Third-party profiling cookies are used to create profiles relating to users, in */}
        {/* order to propose advertising in line with the choices expressed by the users */}
        {/* themselves. */}
        {/* Profiling cookies: We may also use profiling cookies, which are those that create */}
        {/* profiles related to the user and are used in order to send advertising to the user's */}
        {/* browser. */}
        {/* When these types of cookies are used, we will receive your explicit consent. */}
        {/* Support in configuring your browser: You can manage cookies through the */}
        {/* settings of your browser on your device. However, deleting cookies from your */}
        {/* browser may remove the preferences you have set for this Website. */}
        {/* For further information and support, you can also visit the specific help page of the */}
        {/* web browser you are using: */}
        {/* <ul> */}
        {/*   <li>Internet Explorer: http://windows.microsoft.com/en-us/windows-vista/block-or-allow-cookies</li> */}
        {/*   <li>Firefox: https://support.mozilla.org/en-us/kb/enable-and-disable-cookies-website-preferences</li> */}
        {/*   <li>Safari: http://www.apple.com/legal/privacy/</li> */}
        {/*   <li>Chrome: https://support.google.com/accounts/answer/61416?hl=en</li> */}
        {/*   <li>Opera: http://www.opera.com/help/tutorials/security/cookies/</li> */}
        {/* </ul> */}

        <p>
          <strong>Log Data:</strong> Like all websites and mobile applications, the Applicable Services make use of
          log files that store automatic information collected during user visits. The different
          types of log data could be as follows:
        </p>

        <ul>
          <li>internet protocol (IP) address;</li>
          <li>type of browser and device parameters used to connect to the Applicable Services;</li>
          <li>name of the Internet Service Provider (ISP);</li>
          <li>date and time of visit;</li>
          <li>web page of origin of the user (referral) and exit;</li>
          <li>possibly the number of clicks.</li>
        </ul>
        <p>
          The aforementioned information is processed in an automated form and collected in an
          exclusively aggregated manner in order to verify the correct functioning of the site, and
          for security reasons. This information will be processed according to the legitimate
          interests of the Data Controller.
        </p>
        <p>
          For security purposes (spam filters, firewalls, virus detection), the automatically recorded
          data may also possibly include Personal Data such as IP address, which could be used,
          in accordance with applicable laws, in order to block attempts at damage to the Applicable Services
          or damage to other users, or in the case of harmful activities or crime. Such data are
          never used for the identification or profiling of the user, but only for the protection of the
          Applicable Services and our users. Such information will be treated according to the legitimate
          interests of the Data Controller.
        </p>
      </section>

      <section>
        <h3>
          Article 7 - THIRD PARTIES:
        </h3>

        <p>
          We may utilize third-party service providers ("Third-Party Service Providers"), from time
          to time or all the time, to help us with our Applicable Services, and to help serve you.
        </p>

        <p>
          We may use Third-Party Service Providers to assist with information storage (such
          as cloud storage). You may request at any time a list of such service providers.
        </p>

        <p>
          We may provide some of your Personal Data to Third-Party Service Providers in
          order to help us track usage data, such as referral websites, dates and times of
          page requests, etc. We use this information to understand patterns of usage of, and
          to improve, the Applicable Services.
        </p>

        <p>
          We may use Third-Party Service Providers to host the Applicable Services. In this instance, the
          Third-Party Service Provider will have access to your Personal Data.
          <br />
          For example, the Graphl Technologies Website is hosted by <a href="https://kinsta.com/">Kinsta</a>,
          whom we trust due to <a href="https://trust.kinsta.com/">their high compliance record</a>.
        </p>

        <p>
          We may use Third-Party Service Providers to fulfill orders in relation to the Applicable Services.
        </p>

        <p>
          You may opt-in to integrations in our Applicable Services that send information to or receive information
          from a Third-Party Service Provider. When such integrations are available, it will be clear who and what the
          Third-Party Service Provider is, and what data is being sent or received.

          A list of available opt-in Third Party Service Providers and their respective privacy policies includes:

          <ol>
            <li> Bentley System's, Inc.'s iTwin Platform. <a href="https://www.bentley.com/legal/privacy-policy/">Privacy policy</a>. </li>
          </ol>
        </p>


        {/* Some of our Third-Party Service Providers may be located outside of the United */}
        {/* States and may not be subject to U.S. privacy laws. The countries or regions in */}
        {/* which our Third-Party Service Providers may be located include: */}

        {/* ________ */}

        <p>
          We only share your Personal Data with a Third-Party Service Provider if that
          provider agrees to our privacy standards as set out in this Privacy Policy.
          Notwithstanding the other provisions of this Privacy Policy, we may provide your
          Personal Data to a third party or to third parties in order to protect the rights,
          property or safety, of us, our customers or third parties, or as otherwise required by
          law.
        </p>

        <p>
          We will not knowingly share your Personal Data with any third parties other than in
          accordance with this Privacy Policy.
        </p>

        <p>
          If your Personal Data might be provided to a third party in a manner that is other
          than as explained in this Privacy Policy, you will be notified. You will also have the
          opportunity to request that we not share that information.
        </p>

        <p>
          In general, you may request that we do not share your Personal Data with third
          parties. Please contact us via email, if so. Please be advised that you may lose
          access to certain services that we rely on third-party providers for.
        </p>

      </section>

      <section>
        <h3>Article 8 - SOCIAL NETWORKS:</h3>
        The Applicable Services incorporates links to social networks, in order to allow
        easy sharing of content. These links will navigate externally anonymously
        and do not manipulate any cookies or use any referrer schemes, to safeguard
        your privacy.
      </section>

      <section>
        <h3>Article 9 - HOW PERSONAL DATA IS STORED:</h3>

        <p>
          We use secure physical and digital systems to store your Personal Data when
          appropriate. We ensure that your Personal Data is protected against unauthorized
          access, disclosure, or destruction.
        </p>

        <p>
          Please note, however, that no system involving the transmission of information via the
          internet, or the electronic storage of data, is completely secure. However, we take the
          protection and storage of your Personal Data very seriously. We take all reasonable
          steps to protect your Personal Data.
        </p>

        <p>
          Personal Data is stored throughout your relationship with us. We delete your Personal
          Data upon request for cancelation of your account or other general request for the
          deletion of data.
        </p>
        
        <p>
          In the event of a breach of your Personal Data, you will be notified in a reasonable time
          frame, but in no event later than two weeks, and we will follow all applicable laws
          regarding such breach.
        </p>

      </section>
      <section>
        <h3>Article 10 - PURPOSES OF PROCESSING OF PERSONAL DATA:</h3>

        <p>
          We primarily use your Personal Data to help us provide a better experience for you on
          our Applicable Services and to provide you the services and/or information you may have
          requested, such as use of our Applicable Services.
        </p>

        <p>
          Information that does not identify you personally, but that may assist in providing us
          broad overviews of our customer base, will be used for market research or marketing
          efforts. Such information may include, but is not limited to, interests based on your
          cookies.
        </p>

        Personal Data that may be considering identifying may be used for the following:

        <ol style={{ listStyle: "lower-alpha"}}>
          <li> Improving your personal user experience </li>
          <li> Communicating with you about your user account with us </li>
          <li> Marketing and advertising to you, including via email </li>
          <li> Fulfilling your purchases </li>
          <li> Providing customer service to you </li>
          <li> Advising you about updates to the Applicable Services or related Items </li>
        </ol>
      </section>
      <section>
        <h3>Article 11 - DISCLOSURE OF PERSONAL DATA:</h3>

        Although our policy is to maintain the privacy of your Personal Data as described herein,
        we may disclose your Personal Data if we believe that it is reasonable to do so in certain
        cases, in our sole and exclusive discretion. Such cases may include, but are not limited
        to.

        <ol style={{ listStyle: "lower-alpha" }}>
          <li>
            To satisfy any local, state, or Federal laws or regulations
          </li>
          <li>
            To respond to requests, such discovery, criminal, civil, or administrative process,
            subpoenas, court orders, or writs from law enforcement or other governmental or
            legal bodies
          </li>
          <li>
            To bring legal action against a user who has violated the law or violated the terms
            of use of our Applicable Services
          </li>
          <li>
            As may be necessary for the operation of our Applicable Services
          </li>
          <li>
            To generally cooperate with any lawful investigation about our users
          </li>
          <li>
            If we suspect any fraudulent activity on our Applicable Services or if we have noticed any
            activity which may violate our terms or other applicable rules
          </li>
        </ol>

        <p>
          We intend to limit this usage to the fullest extent permissable by law. You may request that we do so,
          by email.
        </p>

      </section>
      <section>
        <h3>Article 12 - CHILD ACCESS:</h3>

        Information collected from children in accordance with this clause is
        collected, used and if applicable, disclosed, in accordance with the general provisions of
        this Privacy Policy.

        We do not expect persons meeting the criteria of "CHILD" to be using the website, but we do
        not restrict their ability to use the Applicable Services.
      </section>

      {/* <section> */}
      {/*   <h3>Article 14 - PUBLIC INFORMATION:</h3> */}

      {/*   We may allow users to post their own content or information publicly on our Applicable Services. */}
      {/*   Such content or information may include, but is not limited to, photographs, status */}
      {/*   updates, blogs, articles, or other personal snippets. Please be aware that any such */}
      {/*   information or content that you may post should be considered entirely public and that */}
      {/*   we do not purport to maintain the privacy of such public information. */}
      {/* </section> */}

      <section>
        <h3>Article 13 - OPTING OUT OF TRANSMITTALS FROM US:</h3>

        From time to time, we may send you informational or marketing communications related
        to our Applicable Services such as announcements or other information. If you wish to opt-out of
        such communications, you may contact the following email: <a href="mailto:mike@graphl.tech">mike@graphl.tech</a>.
        You may also
        click the opt-out link which will be provided at the bottom of any and all such
        communications.

        Please be advised that even though you may opt-out of such communications, you may
        still receive information from us that is specifically about your use of our Applicable Services or
        about your account with us.

        By providing any Personal Data to us, or by using our Applicable Services in any manner, you have
        created a commercial relationship with us. As such, you agree that any email sent from
        us or third-party affiliates, even unsolicited email, shall specifically not be considered
        SPAM, as that term is legally defined.
      </section>
      <section>
        <h3>Article 14 - MODIFYING, DELETING, AND ACCESSING YOUR INFORMATION:</h3>
        If you wish to modify or delete any information we may have about you, or you wish to
        simply access any information we have about you, you may do so from your account
        settings page.
      </section>
      <section>
        <h3>Article 15 - YOUR RIGHTS:</h3>
        You have many rights in relation to your Personal Data. Specifically, your rights are as
        follows:
        <ol>
          <li>the right to be informed about the processing of your Personal Data</li>
          <li>the right to have access to your Personal Data</li>
          <li>the right to update and/or correct your Personal Data</li>
          <li>the right to portability of your Personal Data</li>
          <li>the right to oppose or limit the processing of your Personal Data</li>
          <li>the right to request that we stop processing and delete your Personal Data</li>
          <li>the right to block any Personal Data processing in violation of any applicable law</li>
          <li>the right to launch a complaint with the Federal Trade Commission (FTC) in the</li>
        </ol>
        United States or applicable data protection authority in another jurisdiction
        Such rights can all be exercised by contacting us at the relevant contact information
        listed in this Privacy Policy.
      </section>
      <section>
        <h3>Article 16 - CONTACT INFORMATION:</h3>
        If you have any questions about this Privacy Policy or the way we collect information
        from you, or if you would like to launch a complaint about anything related to this Privacy
        Policy, you may contact us at the following email address: ________.
      </section>
    </div>
  );
};

export default PrivacyPolicy;
