import React, { useState, useEffect, useMemo } from "react";
import { supabase, money, toDMY, VOUCHERS } from "../lib/config";

export function Dashboard() {
  const [stock, setStock] = useState([]);
  const [low, setLow] = useState([]); const [stuck, setStuck] = useState([]);
  const [appr, setAppr] = useState([]); const [overdue, setOverdue] = useState(0);
  const AGE_MIN = 30;  // "old age" threshold for the ageing panel
  useEffect(() => { (async () => {
    const { data: sb } = await supabase.from("stock_summary").select("*").order("part_code"); setStock(sb || []);
    const { data: lo } = await supabase.rpc("low_stock_parts"); setLow(lo || []);
    const { data: st } = await supabase.rpc("stuck_stock", { p_min_days: AGE_MIN }); setStuck(st || []);
    const { data: pa } = await supabase.rpc("pending_approvals"); setAppr(pa || []);
    const { data: od } = await supabase.rpc("overdue_dc_count"); setOverdue(Number(od) || 0);
  })(); }, []);
  const BCOLS = [["RC","rc_bal"],["RCJW","rcjw_bal"],["CC","cc_bal"],["MG","mg_bal"],["PR","pr_bal"],["MR","mr_bal"],["JOBOUT","jobout_bal"]];
  const apprTotal = appr.reduce((s, a) => s + Number(a.cnt), 0);
  const oldStuck = stuck.filter(r => r.days_idle >= AGE_MIN);
  return (<div className="wrap">
    {/* ---- ALERT STRIP: only Overdue DCs, Pending Approvals, Low Stock ---- */}
    <div className="dash-alerts">
      <div className={"alert-tile " + (overdue > 0 ? "warn" : "ok")}>
        <div className="at-n">{overdue}</div><div className="at-l">Overdue DCs</div></div>
      <div className={"alert-tile " + (apprTotal > 0 ? "info" : "ok")}>
        <div className="at-n">{apprTotal}</div><div className="at-l">Pending Approvals</div>
        <div className="at-sub">{appr.map(a => `${a.kind}: ${a.cnt}`).join(" · ")}</div></div>
      <div className={"alert-tile " + (low.length > 0 ? "warn" : "ok")}>
        <div className="at-n">{low.length}</div><div className="at-l">Low-Stock Parts</div></div>
    </div>

    {/* ---- LOW STOCK + AGEING (old only) side by side ---- */}
    <div className="dash-two">
      <div className="card"><div className="card-h"><h2>Low Stock (below reorder)</h2><span className="hint">{low.length} part{low.length !== 1 ? "s" : ""}</span></div>
        <div className="card-b" style={{ padding: 0, maxHeight: 320, overflow: "auto" }}>
          {low.length === 0 ? <div className="empty">All parts above reorder level.</div>
            : <table className="dt"><thead><tr><th>Part</th><th>Bucket</th><th className="num">Balance</th><th className="num">Reorder</th><th className="num">Shortfall</th></tr></thead>
              <tbody>{low.map(r => <tr key={r.part_id}><td><b>{r.part_code}</b> · {r.part_name}</td><td><span className="bkt-tag">{r.bucket}</span></td>
                <td className="num">{money(r.balance)}</td><td className="num">{money(r.reorder_level)}</td><td className="num neg">{money(r.shortfall)}</td></tr>)}</tbody></table>}
        </div>
      </div>
      <div className="card"><div className="card-h"><h2>Ageing — Old Stock</h2><span className="hint">idle ≥ {AGE_MIN} days</span></div>
        <div className="card-b" style={{ padding: 0, maxHeight: 320, overflow: "auto" }}>
          {oldStuck.length === 0 ? <div className="empty">No stock idle for {AGE_MIN}+ days.</div>
            : <table className="dt"><thead><tr><th>Part</th><th>Bucket</th><th className="num">Balance</th><th className="num">Days Idle</th></tr></thead>
              <tbody>{oldStuck.slice(0, 100).map((r, i) => <tr key={i}><td><b>{r.part_code}</b> · {r.part_name}</td><td><span className="bkt-tag">{r.bucket}</span></td>
                <td className="num">{money(r.balance)}</td><td className="num neg">{r.days_idle}</td></tr>)}</tbody></table>}
        </div>
      </div>
    </div>

    <div className="card"><div className="card-h"><h2>Stock Summary</h2></div>
      <div className="card-b" style={{ padding: 0, overflowX: "auto" }}>
        {stock.length === 0 ? <div className="empty">No stock yet. Post a Purchase to begin.</div>
          : <table className="dt"><thead><tr><th>Part</th>{BCOLS.map(([c])=><th key={c} className="num">{c}</th>)}</tr></thead>
            <tbody>{stock.map(r => <tr key={r.part_id}><td>{r.part_code} · {r.part_name}</td>
              {BCOLS.map(([c,k])=><td key={c} className="num">{money(r[k])}</td>)}</tr>)}</tbody></table>}
      </div>
    </div>
  </div>);
}

export function LastUpdatedBanner() {
  const [rows, setRows] = useState([]);
  useEffect(() => { (async () => { const { data } = await supabase.rpc("last_updated_status"); setRows(data || []); })(); }, []);
  if (!rows.length) return null;
  const ageDays = ts => Math.floor((Date.now() - new Date(ts)) / 86400000);
  // spec: PRODUCTION / PROCESS_REJECTION / MATERIAL_REJECTION must be entered daily — flag if last entry's date isn't yesterday (today-1)
  const DAILY = ["PRODUCTION", "PROCESS_REJECTION", "MATERIAL_REJECTION"];
  const isYesterday = ts => { const d = new Date(ts); const y = new Date(); y.setDate(y.getDate() - 1);
    return d.getFullYear() === y.getFullYear() && d.getMonth() === y.getMonth() && d.getDate() === y.getDate(); };
  return (<div className="card" style={{ marginBottom: 20 }}><div className="card-h"><h2>Last Updated Status</h2></div>
    <div className="card-b" style={{ padding: 0 }}><table className="dt"><thead><tr><th>Module</th><th>Entries</th><th>Last Entry</th><th>Age</th></tr></thead>
      <tbody>{rows.map(r => { const a = ageDays(r.last_at);
        const stale = DAILY.includes(r.voucher_type) && !isYesterday(r.last_at);
        return <tr key={r.voucher_type} style={stale ? { background: "#fde8e8" } : null}>
          <td>{(VOUCHERS[r.voucher_type] || {}).label || r.voucher_type}{stale && <span className="pill off" style={{ marginLeft: 8 }}>⚠ not updated for yesterday</span>}</td>
          <td>{r.cnt}</td><td>{new Date(r.last_at).toLocaleString("en-GB")}</td>
          <td><span className={"pill " + (stale ? "off" : a <= 1 ? "on" : "off")}>{a}d ago</span></td></tr>; })}</tbody></table></div>
  </div>);
}

export function OpenDocsBanner() {
  const [rows, setRows] = useState([]);
  const [docF, setDocF] = useState("ALL");          // ALL | PO | SO | DC
  const [q, setQ] = useState("");
  const [sortK, setSortK] = useState("voucher_date");
  const [sortDir, setSortDir] = useState("desc");
  useEffect(() => { (async () => { const { data } = await supabase.rpc("open_documents"); setRows(data || []); })(); }, []);
  const overdue = r => r.due_date && new Date(r.due_date) < new Date(new Date().toDateString());
  const filtered = useMemo(() => {
    let a = rows.filter(r => docF === "ALL" || r.doc === docF);
    const s = q.trim().toLowerCase();
    if (s) a = a.filter(r => [r.voucher_no, r.ledger_name, r.part_code].some(x => (x || "").toLowerCase().includes(s)));
    const dir = sortDir === "asc" ? 1 : -1;
    a = [...a].sort((x, y) => {
      let xv = x[sortK], yv = y[sortK];
      if (sortK === "voucher_date" || sortK === "due_date") { xv = xv ? new Date(xv).getTime() : 0; yv = yv ? new Date(yv).getTime() : 0; }
      else if (["order_qty", "received", "pending", "completion_pct"].includes(sortK)) { xv = +xv || 0; yv = +yv || 0; }
      else { xv = (xv || "").toString().toLowerCase(); yv = (yv || "").toString().toLowerCase(); }
      return xv < yv ? -dir : xv > yv ? dir : 0;
    });
    return a;
  }, [rows, docF, q, sortK, sortDir]);
  const Th = ({ k, label, cls }) => <th className={cls} style={{ cursor: "pointer", whiteSpace: "nowrap" }}
    onClick={() => { if (sortK === k) setSortDir(d => d === "asc" ? "desc" : "asc"); else { setSortK(k); setSortDir("asc"); } }}>
    {label}{sortK === k ? (sortDir === "asc" ? " ▲" : " ▼") : ""}</th>;
  return (<div className="card" style={{ marginBottom: 20 }}><div className="card-h"><h2>Open PO / DC / SO</h2>
      <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
        <div className="seg">{["ALL", "PO", "SO", "DC"].map(d => <button key={d} className={"seg-btn" + (docF === d ? " on" : "")} onClick={() => setDocF(d)}>{d}</button>)}</div>
        <input className="ctl" style={{ width: 200 }} placeholder="Search voucher, party, part…" value={q} onChange={e => setQ(e.target.value)} />
      </div></div>
    <div className="card-b" style={{ padding: 0 }}>{filtered.length === 0 ? <div className="empty">No open documents.</div>
      : <table className="dt"><thead><tr>
          <Th k="doc" label="Doc" /><Th k="voucher_no" label="Voucher" /><Th k="voucher_date" label="Date" /><Th k="due_date" label="Due Date" />
          <Th k="ledger_name" label="Ledger" /><Th k="part_code" label="Part" />
          <Th k="order_qty" label="Order Qty" cls="num" /><Th k="received" label="Received" cls="num" /><Th k="pending" label="Pending" cls="num" /><Th k="completion_pct" label="Completion %" cls="num" />
        </tr></thead>
        <tbody>{filtered.map((r, i) => <tr key={i} style={overdue(r) ? { background: "#fde8e8" } : null}><td><span className="pill on">{r.doc}</span></td><td className="mono">{r.voucher_no}</td><td>{toDMY(r.voucher_date)}</td>
          <td>{r.due_date ? toDMY(r.due_date) : "—"}{overdue(r) && <span className="pill off" style={{ marginLeft: 6 }}>overdue</span>}</td>
          <td>{r.ledger_name || "—"}</td><td>{r.part_code || "—"}</td>
          <td className="num">{money(r.order_qty)}</td><td className="num">{money(r.received)}</td><td className="num">{money(r.pending)}</td>
          <td className="num">{r.completion_pct != null ? (+r.completion_pct).toFixed(1) + "%" : "—"}</td></tr>)}</tbody></table>}
    </div>
  </div>);
}
