import React from "react";

export function Field({ label, req = true, bad, hint, children }) {
  return (<div className={"fld" + (bad ? " bad" : "")}>
    <label>{label}{req && <span className="req">*</span>}</label>
    {children}{hint && <span className="hint">{hint}</span>}</div>);
}
export function Msg({ msg }) {
  if (!msg) return null;
  const icon = msg.t === "ok" ? "✓" : msg.t === "warn" ? "!" : "✕";
  return <div className={`msg ${msg.t}`}><b>{icon}</b><span>{msg.m}</span></div>;
}
export function StockChip({ from, to }) {
  if (!from && !to) return <span className="chip none"><span className="dot" />No stock impact</span>;
  const into = to && !["VENDOR", "CUSTOMER"].includes(to);
  return <span className={"chip " + (into ? "in" : "out")}><span className="dot" />{from} → {to}</span>;
}
