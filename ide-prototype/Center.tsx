import React from "react";

export function Center(props: React.HTMLProps<HTMLDivElement>) {
  return (
    <div style={{
      display: "flex",
      justifyContent: "center",
      alignItems: "center",
      height: "100%",
      width: "100%",
    }}>
      {props.children}
    </div>
  );
}
