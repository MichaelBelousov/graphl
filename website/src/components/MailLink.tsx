import React from "react";

// FIXME: support just giving a `nick` not the full email
export const MailLink = (props: { email: string }) => <a href={`mailto:${props.email}`}>{props.email}</a>;
