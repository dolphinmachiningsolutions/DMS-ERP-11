import React, { useState, useEffect, useMemo } from "react";
import { supabase, money, BUCKETS } from "../lib/config";

// internal buckets in display order
const BUCKETS_ORDER = ["RC", "RCJW", "CC", "MG", "PR", "MR", "JOBOUT"];
const BUCKET_LABEL = { RC: "Raw Casting", RCJW: "RC @ JW", CC: "Coated Casting", MG: "Machined Goods", PR: "Process Rej.", MR: "Material Rej.", JOBOUT: "Sent Out" };

// Which exploded columns are meaningful per bucket. Each col: key, label, kind(in/out/calc), tone
const COL = {
  opening: { label: "Opening", kind: "open" },
  in_purchase: { label: "Purchased", kind: "in" },
  in_rcin_jw: { label: "RC In (JW)", kind: "in" },
  in_dcout_jw: { label: "DC Out (JW)", kind: "in" },
  out_rcin_jw: { label: "RC In (JW)", kind: "out" },
  in_production: { label: "Produced", kind: "in" },
  in_salesreturn: { label: "Sales Ret.", kind: "in" },
  in_procrej: { label: "Proc Rej In", kind: "in" },
  in_matrej: { label: "Mat Rej In", kind: "in" },
  in_rcr: { label: "RCR", kind: "rcin" },
  in_rcm: { label: "RCM", kind: "rcin" },
  TOTAL: { label: "TOTAL", kind: "total" },
  out_dcout_jw: { label: "DC Out (JW)", kind: "out" },
  out_production: { label: "To Prod.", kind: "out" },
  out_sales: { label: "Sales", kind: "out" },
  out_scrap: { label: "Scrap", kind: "out" },
  out_procrej: { label: "Proc Rej", kind: "out" },
  out_matrej: { label: "Mat Rej", kind: "out" },
  out_dn_rc: { label: "DN (RC)", kind: "out" },
  out_dn: { label: "DN", kind: "out" },
  out_dcr: { label: "DCR", kind: "dc" },
  out_dcn: { label: "DCN", kind: "dc" },
  out_dcm: { label: "DCM", kind: "dc" },
  GRS: { label: "Grs Bal", kind: "gross" },
  variance: { label: "Var", kind: "var" },
  bal: { label: "BAL", kind: "bal" },
};

// per-bucket column layout (only show what can flow in/out of that bucket)
const LAYOUT = {
  RC:    ["opening", "in_purchase", "TOTAL", "out_dcout_jw", "out_dn_rc", "out_dcr", "out_dcm", "in_rcr", "in_rcm", "out_dcn", "GRS", "variance", "bal"],
  RCJW:  ["opening", "in_dcout_jw", "TOTAL", "out_rcin_jw", "out_dcr", "out_dcm", "in_rcr", "in_rcm", "out_dcn", "GRS", "variance", "bal"],
  CC:    ["opening", "in_rcin_jw", "TOTAL", "out_production", "out_dcr", "out_dcm", "in_rcr", "in_rcm", "out_dcn", "GRS", "variance", "bal"],
  MG:    ["opening", "in_production", "in_salesreturn", "TOTAL", "out_sales", "out_procrej", "out_matrej", "out_dcr", "out_dcm", "in_rcr", "in_rcm", "out_dcn", "GRS", "variance", "bal"],
  PR:    ["opening", "in_procrej", "in_salesreturn", "TOTAL", "out_scrap", "GRS", "variance", "bal"],
  MR:    ["opening", "in_matrej", "in_salesreturn", "TOTAL", "out_dn", "GRS", "variance", "bal"],
  JOBOUT:["opening", "TOTAL", "out_dcr", "out_dcm", "in_rcr", "in_rcm", "GRS", "variance", "bal"],
};

const INFLOW_KEYS = ["in_purchase", "in_rcin_jw", "in_dcout_jw", "in_production", "in_salesreturn", "in_procrej", "in_matrej", "in_rcr", "in_rcm"];
const OUTFLOW_KEYS = ["out_dn_rc", "out_dn", "out_dcout_jw", "out_rcin_jw", "out_production", "out_sales", "out_scrap", "out_procrej", "out_matrej", "out_dcr", "out_dcn", "out_dcm"];

function rowTotal(r) { return (+r.opening || 0) + INFLOW_KEYS.reduce((s, k) => s + (+r[k] || 0), 0); }
function rowGross(r) { return rowTotal(r) - OUTFLOW_KEYS.reduce((s, k) => s + (+r[k] || 0), 0); }

export function StockSummary() {
  const [rows, setRows] = useState([]); const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState(""); const [mode, setMode] = useState("single"); const [bucket, setBucket] = useState("RC");
  const [groupBy, setGroupBy] = useState("part");  // "part" | "cum"

  useEffect(() => { (async () => {
    const { data } = await supabase.from("stock_explode").select("*").order("part_code");
    setRows(data || []); setLoading(false);
  })(); }, []);

  const isCum = groupBy === "cum";
  // group rows by part OR by cumulative group. Key = part_id, or group label.
  const byPart = useMemo(() => {
    const m = {};
    rows.forEach(r => {
      const gk = isCum ? (r.cumulative_group && r.cumulative_group.trim() ? "grp:" + r.cumulative_group.trim() : r.part_id) : r.part_id;
      const label = isCum && r.cumulative_group && r.cumulative_group.trim() ? r.cumulative_group.trim() : r.part_name;
      const code = isCum && r.cumulative_group && r.cumulative_group.trim() ? `${(m[gk]?.n || 0) + (m[gk]?.buckets?.[r.bucket] ? 0 : 1)} parts` : r.part_code;
      if (!m[gk]) m[gk] = { part_code: isCum ? "" : r.part_code, part_name: label, buckets: {}, ids: new Set() };
      m[gk].ids.add(r.part_id);
      const ex = m[gk].buckets[r.bucket];
      if (!ex) { m[gk].buckets[r.bucket] = { ...r }; }
      else { // sum every numeric column into the existing bucket row
        Object.keys(r).forEach(k => { if (typeof r[k] === "number") ex[k] = (+ex[k] || 0) + (+r[k] || 0); });
      }
    });
    if (isCum) Object.values(m).forEach(g => { g.part_code = g.ids.size > 1 ? `${g.ids.size} parts` : ""; });
    return m;
  }, [rows, isCum]);
  const parts = useMemo(() => Object.entries(byPart)
    .filter(([, p]) => !filter || `${p.part_code} ${p.part_name}`.toLowerCase().includes(filter.toLowerCase()))
    .sort((a, b) => a[1].part_name.localeCompare(b[1].part_name)), [byPart, filter]);

  // KPI chips: total BAL per bucket across all parts
  const kpis = BUCKETS_ORDER.map(b => ({ b, total: rows.filter(r => r.bucket === b).reduce((s, r) => s + (+r.bal || 0), 0) }));

  function cellVal(r, key) {
    if (!r) return 0;
    if (key === "TOTAL") return rowTotal(r);
    if (key === "GRS") return rowGross(r);
    if (key === "bal") return +r.bal || 0;
    return +r[key] || 0;
  }
  const toneClass = k => "ex-" + (COL[k]?.kind || "in");

  function renderBucketTable(bk) {
    const cols = LAYOUT[bk];
    const sums = {}; cols.forEach(k => sums[k] = 0);
    parts.forEach(([pid]) => { const r = byPart[pid].buckets[bk]; cols.forEach(k => sums[k] += cellVal(r, k)); });
    return (<div className="ex-block">
      <div className="ex-bucket-title">{BUCKET_LABEL[bk]} <span>@ COMPANY</span></div>
      <div className="ex-scroll"><table className="ex-grid"><thead><tr>
        <th className="ex-partcol">PART NAME</th>
        {cols.map(k => <th key={k} className={toneClass(k)}>{COL[k].label}</th>)}
      </tr></thead><tbody>
        {parts.map(([pid, p]) => { const r = byPart[pid].buckets[bk]; const bal = cellVal(r, "bal"); const neg = bal < 0;
          return <tr key={pid} className={neg ? "ex-negrow" : ""}>
            <td className="ex-partcol">{p.part_name} <span className="ex-code">{p.part_code}</span></td>
            {cols.map(k => { const v = cellVal(r, k);
              const show = (k === "variance" && v === 0) ? "0" : (k === "opening" && v === 0) ? "0" : v === 0 ? "0" : money(v).replace(/\.00$/, "");
              return <td key={k} className={toneClass(k) + (k === "bal" && neg ? " ex-neg" : "")}>{k === "variance" && v === 0 ? "—" : show}</td>; })}
          </tr>; })}
        <tr className="ex-sumrow"><td className="ex-partcol">TOTAL · {parts.length} parts</td>
          {cols.map(k => <td key={k} className={toneClass(k)}>{money(sums[k]).replace(/\.00$/, "")}</td>)}</tr>
      </tbody></table></div>
    </div>);
  }

  return (<div className="ex-wrap">
    <div className="ex-head">
      <div><div className="ex-h1">Stock Summary</div><div className="ex-sub">{parts.length} parts · {mode === "single" ? "1 bucket" : BUCKETS_ORDER.length + " buckets"} · exploded movements</div></div>
    </div>

    <div className="ex-legend">
      <span className="lg ex-open">Opening</span><span className="lg ex-total">Total</span><span className="lg ex-bal">Balance</span>
      <span className="lg ex-dc">DC Out (DCR/DCN/DCM)</span><span className="lg ex-rcin">RC In (RCR/RCM)</span>
      <span className="lg ex-neg-lg">Negative Alert</span><span className="lg ex-gross">Gross Balance</span><span className="lg ex-var">Variance ±</span>
    </div>

    <div className="ex-toolbar">
      <input className="ctl" style={{ width: 240 }} placeholder={isCum ? "Filter group…" : "Filter part…"} value={filter} onChange={e => setFilter(e.target.value)} />
      <div className="ex-modes">
        <button className={!isCum ? "on" : ""} onClick={() => setGroupBy("part")}>By Part</button>
        <button className={isCum ? "on" : ""} onClick={() => setGroupBy("cum")}>By Cumulative Group</button>
      </div>
      <div className="ex-modes">
        <button className={mode === "single" ? "on" : ""} onClick={() => setMode("single")}>Single bucket</button>
        <button className={mode === "wide" ? "on" : ""} onClick={() => setMode("wide")}>All buckets</button>
      </div>
      {mode === "single" && <select className="ctl" style={{ width: 180 }} value={bucket} onChange={e => setBucket(e.target.value)}>
        {BUCKETS_ORDER.map(b => <option key={b} value={b}>{BUCKET_LABEL[b]}</option>)}</select>}
    </div>

    {loading ? <div className="empty">Loading…</div>
      : parts.length === 0 ? <div className="empty">No parts. Post a Purchase or run the demo seed.</div>
      : mode === "single" ? renderBucketTable(bucket)
      : <div className="ex-widewrap">{BUCKETS_ORDER.map(b => renderBucketTable(b))}</div>}
  </div>);
}
