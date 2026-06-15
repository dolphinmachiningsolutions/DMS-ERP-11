import React, { useState, useEffect } from "react";
import { supabase, money, toDMY, VOUCHERS } from "../lib/config";
import { Msg } from "../ui/primitives";
import { exportXLSX, exportHTML, exportPDF } from "../lib/exporters";

const BCOLS = [["RC", "rc_bal"], ["RCJW", "rcjw_bal"], ["CC", "cc_bal"], ["MG", "mg_bal"], ["PR", "pr_bal"], ["MR", "mr_bal"], ["JOBOUT", "jobout_bal"]];

export function StockSummary() {
  const [rows, setRows] = useState([]); const [cumRows, setCumRows] = useState([]); const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState(""); const [mode, setMode] = useState("part");  // "part" | "cum"
  useEffect(() => { (async () => {
    const { data } = await supabase.from("stock_summary").select("*").order("part_code"); setRows(data || []);
    const { data: cg } = await supabase.rpc("stock_summary_cumulative"); setCumRows(cg || []);
    setLoading(false);
  })(); }, []);
  const isCum = mode === "cum";
  const src = isCum ? cumRows : rows;
  const shown = src.filter(r => !filter || (isCum ? `${r.grp}` : `${r.part_code} ${r.part_name}`).toLowerCase().includes(filter.toLowerCase()));
  const tot = c => shown.reduce((s, r) => s + (+r[c] || 0), 0);
  return (<div className="wrap">
    <div className="card"><div className="card-h"><h2>Stock Summary</h2>
      <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
        <div className="seg"><button className={"seg-btn"+(!isCum?" on":"")} onClick={()=>setMode("part")}>By Part</button><button className={"seg-btn"+(isCum?" on":"")} onClick={()=>setMode("cum")}>By Cumulative Group</button></div>
        <input className="ctl" style={{ width: 200 }} placeholder={isCum?"Filter group…":"Filter part…"} value={filter} onChange={e => setFilter(e.target.value)} />
      </div></div>
      <div className="card-b" style={{ padding: 0, overflowX: "auto" }}>
        {loading ? <div className="empty">Loading…</div> : shown.length === 0 ? <div className="empty">No {isCum?"groups":"parts"}.</div>
          : <table className="grid"><thead><tr><th>{isCum?"Cumulative Group":"Part"}</th>{isCum&&<th className="amt">Parts</th>}{BCOLS.map(([c]) => <th key={c} className="amt">{c}</th>)}</tr></thead>
            <tbody>{shown.map((r,i) => <tr key={isCum?r.grp:r.part_id}>
              <td style={{ textAlign: "left" }}>{isCum ? <b>{r.grp}</b> : `${r.part_code} · ${r.part_name}`}</td>
              {isCum && <td className="amt" style={{color:"var(--muted)"}}>{r.members}</td>}
              {BCOLS.map(([c, k]) => <td key={c} className="amt" style={(+r[k]) < 0 ? { color: "var(--err)", fontWeight: 700 } : null}>{money(r[k])}</td>)}</tr>)}</tbody>
            <tfoot><tr><td style={{ textAlign: "left" }}>Total</td>{isCum&&<td className="amt"></td>}{BCOLS.map(([c, k]) => <td key={c} className="amt">{money(tot(k))}</td>)}</tr></tfoot></table>}
      </div>
    </div>
  </div>);
}

export function PhysicalStock({ user }) {
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10)); const [grid, setGrid] = useState([]); const [phys, setPhys] = useState({});
  const [msg, setMsg] = useState(null); const [loading, setLoading] = useState(true); const [filter, setFilter] = useState("");
  const [hideZero, setHideZero] = useState(true); const [onlyDiff, setOnlyDiff] = useState(false); const [saving, setSaving] = useState(false);
  async function load() { setLoading(true); const { data } = await supabase.rpc("get_recon_grid"); setGrid(data || []); const seed = {}; (data || []).forEach(r => seed[`${r.part_id}:${r.bucket}`] = String(r.system_qty)); setPhys(seed); setLoading(false); }
  useEffect(() => { load(); }, []);
  const key = r => `${r.part_id}:${r.bucket}`;
  const variance = r => { const p = parseFloat(phys[key(r)]); return isNaN(p) ? 0 : +(p - r.system_qty).toFixed(2); };
  async function save() {
    setSaving(true);
    const rows = grid.map(r => ({ part_id: r.part_id, bucket: r.bucket, physical_qty: +phys[key(r)] || 0 }))
      .filter(r => { const g = grid.find(x => x.part_id === r.part_id && x.bucket === r.bucket); return r.physical_qty !== +g.system_qty; });
    if (!rows.length) { setSaving(false); return setMsg({ t: "warn", m: "Nothing to post — no counted quantity differs from the system." }); }
    const { data, error } = await supabase.rpc("post_reconciliation", { p_date: date, p_user: user?.username || "system", p_rows: rows }); setSaving(false);
    if (error) return setMsg({ t: "err", m: error.message }); setMsg({ t: "ok", m: `Posted — ${data} ${data === 1 ? "adjustment" : "adjustments"} recorded.` }); load();
  }
  const diffCount = grid.filter(r => variance(r) !== 0).length;
  let shown = grid.filter(r => !filter || `${r.part_code} ${r.part_name}`.toLowerCase().includes(filter.toLowerCase()));
  if (hideZero) shown = shown.filter(r => +r.system_qty !== 0 || variance(r) !== 0);
  if (onlyDiff) shown = shown.filter(r => variance(r) !== 0);
  let lastPart = null;
  return (<div className="dsx"><Msg msg={msg} />
    <div className="dsx-head">
      <div><h1>Physical Stock Reconciliation</h1><div className="sub">Enter the counted quantity per bucket; the variance posts as an adjustment.</div></div>
      <div className="dsx-head-actions">
        {diffCount > 0 && <span className="dsx-badge warn"><span className="dot" />{diffCount} {diffCount === 1 ? "difference" : "differences"}</span>}
        <button className="dsx-btn primary" onClick={save} disabled={saving}>{saving ? "Posting…" : "Post reconciliation"}</button>
      </div>
    </div>
    <div className="dsx-card">
      <div className="dsx-card-h">
        <h2>Count sheet</h2>
        <div style={{ display: "flex", gap: 14, alignItems: "center", flexWrap: "wrap" }}>
          <input className="dsx-input" style={{ width: 150, height: 36 }} type="date" value={date} onChange={e => setDate(e.target.value)} />
          <label className="dsx-check"><input type="checkbox" checked={hideZero} onChange={e => setHideZero(e.target.checked)} />Hide empty</label>
          <label className="dsx-check"><input type="checkbox" checked={onlyDiff} onChange={e => setOnlyDiff(e.target.checked)} />Only differences</label>
          <input className="dsx-input" style={{ width: 200, height: 36 }} placeholder="Search part…" value={filter} onChange={e => setFilter(e.target.value)} />
        </div>
      </div>
      <div className="dsx-card-b flush">
        {loading ? <div className="dsx-empty">Loading…</div> : shown.length === 0 ? <div className="dsx-empty"><div className="big">Nothing to show</div>Adjust the filters to see stock rows.</div>
          : <div className="dsx-table-wrap" style={{ maxHeight: "62vh", overflowY: "auto" }}>
            <table className="dsx-table"><thead><tr><th>Part</th><th className="c">Bucket</th><th className="num">System</th><th className="num">Counted</th><th className="r">Variance</th></tr></thead>
              <tbody>{shown.map(r => { const v = variance(r); const newPart = r.part_code !== lastPart; lastPart = r.part_code;
                return <tr key={key(r)} style={newPart ? { borderTop: "2px solid var(--line)" } : null}>
                  <td>{newPart ? <span><span className="dsx-strong">{r.part_code}</span> <span className="dsx-muted">{r.part_name}</span></span> : <span className="dsx-muted" style={{ paddingLeft: 14 }}>↳</span>}</td>
                  <td className="c"><span className="dsx-badge off">{r.bucket}</span></td>
                  <td className="num">{money(r.system_qty)}</td>
                  <td className="num" style={{ padding: 0 }}><input className="dsx-matrix-in" type="number" value={phys[key(r)] ?? ""} onChange={e => setPhys(s => ({ ...s, [key(r)]: e.target.value }))} /></td>
                  <td className="num" style={v === 0 ? { color: "var(--muted-2)" } : v > 0 ? { color: "var(--ok)", fontWeight: 700 } : { color: "var(--err)", fontWeight: 700 }}>{v === 0 ? "—" : v > 0 ? `+${v}` : `${v}`}</td></tr>; })}</tbody></table>
          </div>}
      </div>
    </div>
  </div>);
}

export function StockView() {
  const [mode, setMode] = useState("statement");  // "statement" (snapshot) | "ledger" (movements)
  return (<div className="wrap">
    <div className="seg-toggle" style={{ marginBottom: 14 }}>
      <button className={"seg" + (mode === "statement" ? " on" : "")} onClick={() => setMode("statement")}>Statement (current balances)</button>
      <button className={"seg" + (mode === "ledger" ? " on" : "")} onClick={() => setMode("ledger")}>Ledger (movement history)</button>
    </div>
    {mode === "statement" ? <StockStatementSnapshot /> : <StockLedger embedded />}
  </div>);
}

// Statement = a true current-balance snapshot per part across buckets (NOT a movement list)
function StockStatementSnapshot() {
  const [rows, setRows] = useState([]); const [loading, setLoading] = useState(true); const [q, setQ] = useState("");
  useEffect(() => { (async () => { const { data } = await supabase.from("stock_summary").select("*").order("part_code"); setRows(data || []); setLoading(false); })(); }, []);
  const shown = rows.filter(r => !q || `${r.part_code} ${r.part_name}`.toLowerCase().includes(q.toLowerCase()));
  const BK = [["rc_bal", "RC"], ["rcjw_bal", "RC@JW"], ["cc_bal", "CC"], ["mg_bal", "MG"], ["pr_bal", "PR"], ["mr_bal", "MR"], ["jobout_bal", "Sent Out"]];
  const tot = (k) => shown.reduce((s, r) => s + (+r[k] || 0), 0);
  return (<div className="card"><div className="card-h"><h2>Stock Statement — Current Balances</h2><input className="ctl" style={{ width: 220 }} placeholder="Search part…" value={q} onChange={e => setQ(e.target.value)} /></div>
    <div className="card-b" style={{ padding: 0, maxHeight: "70vh", overflow: "auto" }}>
      {loading ? <div className="empty">Loading…</div> : shown.length === 0 ? <div className="empty">No parts.</div>
        : <table className="dt ledger-table"><thead><tr><th>Part</th>{BK.map(([, l]) => <th key={l} className="num">{l}</th>)}</tr></thead>
          <tbody>{shown.map(r => <tr key={r.part_id}><td><b>{r.part_code}</b> · {r.part_name}</td>
            {BK.map(([k]) => <td key={k} className={"num" + ((+r[k] || 0) < 0 ? " neg" : "")}>{money(r[k] || 0)}</td>)}</tr>)}</tbody>
          <tfoot><tr><td style={{ textAlign: "right", fontWeight: 700 }}>Totals</td>{BK.map(([k]) => <td key={k} className="num"><b>{money(tot(k))}</b></td>)}</tr></tfoot>
        </table>}
    </div>
  </div>);
}

export function StockStatement() { return <StockView />; }  // back-compat alias

export function PartLedger() {
  const buckets = ["RC", "RCJW", "CC", "MG", "PR", "MR", "JOBOUT"];
  const BLABEL = { RC: "Raw Casting", RCJW: "RC @ JW", CC: "Coated Casting", MG: "Machined Goods", PR: "Process Rej.", MR: "Material Rej.", JOBOUT: "Sent Out" };
  const [parts, setParts] = useState([]); const [part, setPart] = useState(""); const [bucket, setBucket] = useState("RC");
  const [from, setFrom] = useState(""); const [to, setTo] = useState("");
  const [rows, setRows] = useState([]); const [loaded, setLoaded] = useState(false);
  const [mode, setMode] = useState("part"); const [groups, setGroups] = useState([]); const [grp, setGrp] = useState("");
  const [vendors, setVendors] = useState([]); const [vendor, setVendor] = useState("");
  const [vsum, setVsum] = useState(null);      // part→vendor summary (By Part)
  const [vpRows, setVpRows] = useState([]);     // vendor→part rows (By Party)
  const [vPart, setVPart] = useState("");       // By Party: part filter ("" = all)
  const [vView, setVView] = useState("summary"); // By Party: 'summary' | 'docs'
  const [vDocs, setVDocs] = useState([]);       // By Party: document-wise rows
  useEffect(() => { (async () => {
    const { data } = await supabase.from("part").select("id,part_code,part_name").eq("status", "Active").order("part_code"); setParts(data || []);
    const { data: cg } = await supabase.rpc("cumulative_groups"); setGroups((cg||[]).map(x=>x.grp));
    const { data: vd } = await supabase.from("ledger").select("id,ledger_code,ledger_name").like("ledger_type","Vendor%").eq("status","Active").order("ledger_code"); setVendors(vd || []);
  })(); }, []);
  const isCum = mode === "cum"; const isVendor = mode === "vendor";
  async function run() {
    if (isVendor) { if (!vendor) return;
      const part_arg = vPart || null;
      const { data: s } = await supabase.rpc("vendor_part_summary", { p_ledger: vendor, p_from: from || null, p_to: to || null, p_part: part_arg }); setVpRows(s || []);
      const { data: d } = await supabase.rpc("vendor_doc_lines", { p_ledger: vendor, p_from: from || null, p_to: to || null, p_part: part_arg }); setVDocs(d || []);
      setLoaded(true); return; }
    if (isCum) { if (!grp) return; const { data } = await supabase.rpc("part_ledger_group", { p_group: grp, p_bucket: bucket, p_from: from || null, p_to: to || null }); setRows(data || []); setVsum(null); setLoaded(true); }
    else { if (!part) return;
      const { data } = await supabase.rpc("part_ledger_full", { p_part: part, p_bucket: bucket, p_from: from || null, p_to: to || null }); setRows(data || []);
      const { data: vs } = await supabase.rpc("part_vendor_summary", { p_part: part, p_from: from || null, p_to: to || null }); setVsum(vs || []);
      setLoaded(true); }
  }
  const partObj = parts.find(p => p.id === part);
  const moves = rows.filter(r => r.voucher_type !== "OPENING BALANCE");
  const opening = rows.find(r => r.voucher_type === "OPENING BALANCE");
  const totalIn = moves.reduce((s, r) => s + (+r.inward || 0), 0);
  const totalOut = moves.reduce((s, r) => s + (+r.outward || 0), 0);
  const closing = rows.length ? +rows[rows.length - 1].running : 0;
  const EXP_COLS = [{ key: "ledger_date", label: "Date", kind: "date" }, { key: "voucher_type", label: "Type" }, { key: "voucher_no", label: "Voucher No" },
    { key: "vendor", label: "Party" }, { key: "counterparty", label: "Counterparty" }, { key: "inward", label: "Inward", kind: "num" }, { key: "outward", label: "Outward", kind: "num" }, { key: "running", label: "Balance", kind: "num" }];
  function doExport(fmt) { const title = `Part Ledger — ${partObj?.part_code} (${bucket})`;
    if (fmt === "xlsx") exportXLSX(title, EXP_COLS, rows); else if (fmt === "html") exportHTML(title, title, EXP_COLS, rows); else exportPDF(title, EXP_COLS, rows); }
  return (<div className="wrap">
    <div className="card"><div className="card-h"><h2>Part Ledger</h2>
      <div className="seg"><button className={"seg-btn"+(mode==="part"?" on":"")} onClick={()=>{setMode("part");setLoaded(false);}}>By Part</button><button className={"seg-btn"+(mode==="vendor"?" on":"")} onClick={()=>{setMode("vendor");setLoaded(false);}}>By Party</button><button className={"seg-btn"+(mode==="cum"?" on":"")} onClick={()=>{setMode("cum");if(bucket==="ALL")setBucket("RC");setLoaded(false);}}>Cumulative</button></div></div>
      <div className="card-b"><div className="fg">
        {isVendor
          ? <><div className="fld"><label>Party</label><select className="ctl" value={vendor} onChange={e => setVendor(e.target.value)}><option value="">— select vendor —</option>{vendors.map(v => <option key={v.id} value={v.id}>{v.ledger_code} · {v.ledger_name}</option>)}</select></div>
              <div className="fld"><label>Part</label><select className="ctl" value={vPart} onChange={e => setVPart(e.target.value)}><option value="">All parts</option>{parts.map(p => <option key={p.id} value={p.id}>{p.part_code} · {p.part_name}</option>)}</select></div></>
          : isCum
          ? <div className="fld"><label>Cumulative Group</label><select className="ctl" value={grp} onChange={e => setGrp(e.target.value)}><option value="">— select group —</option>{groups.map(g => <option key={g} value={g}>{g}</option>)}</select></div>
          : <div className="fld"><label>Part</label><select className="ctl" value={part} onChange={e => setPart(e.target.value)}><option value="">— select part —</option>{parts.map(p => <option key={p.id} value={p.id}>{p.part_code} · {p.part_name}</option>)}</select></div>}
        {!isVendor && <div className="fld"><label>Bucket</label><select className="ctl" value={bucket} onChange={e => setBucket(e.target.value)}>{mode==="part" && <option value="ALL">All Buckets</option>}{buckets.map(b => <option key={b} value={b}>{BLABEL[b]}</option>)}</select></div>}
        <div className="fld"><label>From</label><input className="ctl" type="date" value={from} onChange={e => setFrom(e.target.value)} /></div>
        <div className="fld"><label>To</label><input className="ctl" type="date" value={to} onChange={e => setTo(e.target.value)} /></div>
      </div></div>
      <div className="row-actions"><button className="btn" onClick={run} disabled={isVendor?!vendor:isCum?!grp:!part}>View {isVendor?"Purchases":"Ledger"}</button>
        {loaded && !isVendor && rows.length > 0 && <><button className="btn ghost" onClick={() => doExport("xlsx")}>Excel</button><button className="btn ghost" onClick={() => doExport("html")}>HTML</button><button className="btn ghost" onClick={() => doExport("pdf")}>PDF</button></>}</div>
    </div>
    {loaded && !isVendor && (partObj || isCum) && <div className="ledger-summary">
      <div className="ls-card"><div className="l">{isCum?"Cumulative Group":"Part"}</div><div className="v">{isCum ? grp : `${partObj.part_code} · ${partObj.part_name}`}</div></div>
      <div className="ls-card"><div className="l">Bucket</div><div className="v">{bucket==="ALL"?"All Buckets":BLABEL[bucket]}</div></div>
      <div className="ls-card"><div className="l">Opening</div><div className="v num">{money(opening?.running || 0)}</div></div>
      <div className="ls-card"><div className="l">Total In</div><div className="v num pos">{money(totalIn)}</div></div>
      <div className="ls-card"><div className="l">Total Out</div><div className="v num neg">{money(totalOut)}</div></div>
      <div className="ls-card hl"><div className="l">Closing Balance</div><div className="v num">{money(closing)}</div></div>
    </div>}

    {/* By Part: vendor-wise purchase summary at top */}
    {loaded && !isVendor && !isCum && vsum && vsum.length > 0 && <div className="card"><div className="card-h"><h2>Purchased by Party</h2></div>
      <div className="card-b" style={{ padding: 0 }}><table className="dt"><thead><tr><th>Party</th><th className="num">Purchased</th><th className="num">Returned</th><th className="num">Net</th><th className="num">Value</th><th className="num"># Purchases</th></tr></thead>
        <tbody>{vsum.map((v,i)=><tr key={i}><td><b>{v.vendor_code}</b> · {v.vendor_name}</td><td className="num pos">{money(v.purchased)}</td><td className="num neg">{(+v.returned)?money(v.returned):"—"}</td><td className="num"><b>{money(v.net)}</b></td><td className="num">{money(v.value)}</td><td className="num">{v.purchases}</td></tr>)}</tbody>
        <tfoot><tr><td style={{textAlign:"right"}}>Total</td><td className="num pos">{money(vsum.reduce((s,v)=>s+(+v.purchased||0),0))}</td><td className="num neg">{money(vsum.reduce((s,v)=>s+(+v.returned||0),0))}</td><td className="num"><b>{money(vsum.reduce((s,v)=>s+(+v.net||0),0))}</b></td><td className="num">{money(vsum.reduce((s,v)=>s+(+v.value||0),0))}</td><td className="num">{vsum.reduce((s,v)=>s+(+v.purchases||0),0)}</td></tr></tfoot>
      </table></div></div>}

    {/* By Party: parts purchased from this vendor */}
    {loaded && isVendor && <div className="card">
      <div className="card-h"><h2>{vendors.find(v=>v.id===vendor)?.ledger_name||""}{vPart?` · ${parts.find(p=>p.id===vPart)?.part_code||""}`:""}</h2>
        <div className="seg"><button className={"seg-btn"+(vView==="summary"?" on":"")} onClick={()=>setVView("summary")}>Summary</button><button className={"seg-btn"+(vView==="docs"?" on":"")} onClick={()=>setVView("docs")}>Document-wise</button></div>
      </div>
      <div className="card-b" style={{ padding: 0 }}>
        {vView==="summary"
          ? (vpRows.length === 0 ? <div className="empty">No purchases from this vendor in range.</div>
            : <table className="dt"><thead><tr><th>Part</th><th className="num">Purchased</th><th className="num">Returned</th><th className="num">Net</th><th className="num">Value</th><th className="num"># Purchases</th></tr></thead>
              <tbody>{vpRows.map((p,i)=><tr key={i}><td><b>{p.part_code}</b> · {p.part_name}</td><td className="num pos">{money(p.purchased)}</td><td className="num neg">{(+p.returned)?money(p.returned):"—"}</td><td className="num"><b>{money(p.net)}</b></td><td className="num">{money(p.value)}</td><td className="num">{p.purchases}</td></tr>)}</tbody>
              <tfoot><tr><td style={{textAlign:"right"}}>Total</td><td className="num pos">{money(vpRows.reduce((s,p)=>s+(+p.purchased||0),0))}</td><td className="num neg">{money(vpRows.reduce((s,p)=>s+(+p.returned||0),0))}</td><td className="num"><b>{money(vpRows.reduce((s,p)=>s+(+p.net||0),0))}</b></td><td className="num">{money(vpRows.reduce((s,p)=>s+(+p.value||0),0))}</td><td className="num">{vpRows.reduce((s,p)=>s+(+p.purchases||0),0)}</td></tr></tfoot>
            </table>)
          : (vDocs.length === 0 ? <div className="empty">No documents for this selection.</div>
            : <table className="dt"><thead><tr><th>Date</th><th>Doc Type</th><th>Voucher No</th><th>Part</th><th className="num">Qty</th><th className="num">Unit Price</th><th className="num">Value</th></tr></thead>
              <tbody>{vDocs.map((d,i)=><tr key={i}><td>{toDMY(d.voucher_date)}</td>
                <td>{d.is_return ? <span className="pill" style={{background:"var(--err-bg)",color:"var(--err)"}}>{d.doc_type}</span> : <span className="pill on">{d.doc_type}</span>}</td>
                <td className="mono">{d.voucher_no}</td><td><b>{d.part_code}</b> · {d.part_name}</td>
                <td className={"num "+(d.is_return?"neg":"pos")}>{d.is_return?"-":""}{money(d.qty)}</td>
                <td className="num">{money(d.unit_price)}</td>
                <td className={"num "+(d.is_return?"neg":"")}>{d.is_return?"-":""}{money(d.value)}</td></tr>)}</tbody>
              <tfoot><tr><td colSpan={4} style={{textAlign:"right"}}>Net</td>
                <td className="num"><b>{money(vDocs.reduce((s,d)=>s+(d.is_return?-1:1)*(+d.qty||0),0))}</b></td><td></td>
                <td className="num"><b>{money(vDocs.reduce((s,d)=>s+(d.is_return?-1:1)*(+d.value||0),0))}</b></td></tr></tfoot>
            </table>)}
      </div></div>}
    {loaded && !isVendor && <div className="card"><div className="card-b" style={{ padding: 0 }}>
      {rows.length === 0 ? <div className="empty">No data for this selection.</div>
        : <table className="dt ledger-table"><thead><tr><th className="c-sno">#</th><th>Date</th><th>Voucher Type</th><th>Voucher No</th><th>Party</th><th>Counterparty</th><th>Ref</th><th className="num">Inward</th><th className="num">Outward</th><th className="num">Balance</th></tr></thead>
          <tbody>{rows.map((r, i) => { const isOpen = r.voucher_type === "OPENING BALANCE";
            return <tr key={i} className={isOpen ? "ledger-open" : ""}>
              <td className="c-sno">{isOpen ? "" : r.seq - 1}</td>
              <td>{r.ledger_date ? toDMY(r.ledger_date) : "—"}</td>
              <td>{isOpen ? <b>Opening Balance</b> : r.voucher_type}</td>
              <td className="mono">{r.voucher_no || "—"}</td>
              <td>{r.vendor || ""}</td>
              <td>{r.counterparty ? <span className="bkt-tag">{r.counterparty}</span> : "—"}</td>
              <td>{r.ref_no || "—"}</td>
              <td className="num pos">{(+r.inward) ? money(r.inward) : ""}</td>
              <td className="num neg">{(+r.outward) ? money(r.outward) : ""}</td>
              <td className="num"><b>{money(r.running)}</b></td></tr>; })}</tbody>
          <tfoot><tr><td colSpan={7} style={{ textAlign: "right" }}>Totals</td><td className="num pos">{money(totalIn)}</td><td className="num neg">{money(totalOut)}</td><td className="num"><b>{money(closing)}</b></td></tr></tfoot>
        </table>}
    </div></div>}
  </div>);
}

export function StockLedger({ embedded } = {}) {
  const buckets = ["RC", "RCJW", "CC", "MG", "PR", "MR", "JOBOUT"];
  const [rows, setRows] = useState([]); const [loading, setLoading] = useState(false); const [loaded, setLoaded] = useState(false);
  const [parts, setParts] = useState([]); const [vtypes, setVtypes] = useState([]);
  const [fPart, setFPart] = useState(""); const [fBucket, setFBucket] = useState(""); const [fType, setFType] = useState("");
  const [from, setFrom] = useState(""); const [to, setTo] = useState(""); const [search, setSearch] = useState("");
  useEffect(() => { (async () => {
    const { data: p } = await supabase.from("part").select("id,part_code,part_name").eq("status", "Active").order("part_code"); setParts(p || []);
    setVtypes(Object.entries(VOUCHERS).filter(([, v]) => v.from || v.to).map(([k, v]) => [k, v.label]));
    run();
  })(); }, []);
  async function run() {
    setLoading(true);
    const { data } = await supabase.rpc("stock_ledger_full", { p_part: fPart || null, p_bucket: fBucket || null, p_vtype: fType || null, p_from: from || null, p_to: to || null });
    setRows(data || []); setLoading(false); setLoaded(true);
  }
  const shown = rows.filter(r => !search || `${r.voucher_no} ${r.part_code} ${r.part_name} ${r.ledger_name} ${r.from_bucket} ${r.to_bucket}`.toLowerCase().includes(search.toLowerCase()));
  const totQty = shown.reduce((s, r) => s + (+r.qty || 0), 0);
  const EXP_COLS = [{ key: "ledger_date", label: "Date", kind: "date" }, { key: "voucher_no", label: "Voucher No" }, { key: "voucher_type", label: "Type" },
    { key: "part_code", label: "Part Code" }, { key: "part_name", label: "Part Name" }, { key: "ledger_name", label: "Ledger" },
    { key: "from_bucket", label: "From" }, { key: "to_bucket", label: "To" }, { key: "qty", label: "Qty", kind: "num" }, { key: "note", label: "Note" }];
  function doExport(fmt) { const title = "Stock Ledger"; if (fmt === "xlsx") exportXLSX(title, EXP_COLS, shown); else if (fmt === "html") exportHTML(title, title, EXP_COLS, shown); else exportPDF(title, EXP_COLS, shown); }
  const Wrap = embedded ? React.Fragment : "div";
  const wrapProps = embedded ? {} : { className: "wrap" };
  return (<Wrap {...wrapProps}>
    <div className="card"><div className="card-h"><h2>Stock Ledger — Movement Journal</h2></div>
      <div className="card-b"><div className="fg">
        <div className="fld"><label>Part</label><select className="ctl" value={fPart} onChange={e => setFPart(e.target.value)}><option value="">All parts</option>{parts.map(p => <option key={p.id} value={p.id}>{p.part_code} · {p.part_name}</option>)}</select></div>
        <div className="fld"><label>Bucket</label><select className="ctl" value={fBucket} onChange={e => setFBucket(e.target.value)}><option value="">All buckets</option>{buckets.map(b => <option key={b} value={b}>{b}</option>)}</select></div>
        <div className="fld"><label>Voucher Type</label><select className="ctl" value={fType} onChange={e => setFType(e.target.value)}><option value="">All types</option>{vtypes.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
        <div className="fld"><label>From</label><input className="ctl" type="date" value={from} onChange={e => setFrom(e.target.value)} /></div>
        <div className="fld"><label>To</label><input className="ctl" type="date" value={to} onChange={e => setTo(e.target.value)} /></div>
        <div className="fld"><label>Search</label><input className="ctl" placeholder="voucher / part / ledger…" value={search} onChange={e => setSearch(e.target.value)} /></div>
      </div></div>
      <div className="row-actions"><button className="btn" onClick={run}>Apply Filters</button>
        {loaded && shown.length > 0 && <><button className="btn ghost" onClick={() => doExport("xlsx")}>Excel</button><button className="btn ghost" onClick={() => doExport("html")}>HTML</button><button className="btn ghost" onClick={() => doExport("pdf")}>PDF</button></>}
        <span style={{ marginLeft: "auto", color: "var(--muted)", fontSize: 12, alignSelf: "center" }}>{shown.length} movements</span></div>
    </div>
    <div className="card"><div className="card-b" style={{ padding: 0, maxHeight: "64vh", overflow: "auto" }}>
      {loading ? <div className="empty">Loading…</div> : shown.length === 0 ? <div className="empty">No movements match.</div>
        : <table className="dt ledger-table"><thead><tr><th>Date</th><th>Voucher No</th><th>Type</th><th>Part</th><th>Ledger</th><th>From</th><th>To</th><th className="num">Qty</th><th>Note</th></tr></thead>
          <tbody>{shown.map((r, i) => <tr key={i}>
            <td>{toDMY(r.ledger_date)}</td><td className="mono">{r.voucher_no || "—"}</td><td>{r.voucher_type}</td>
            <td>{r.part_code}{r.part_name ? " · " + r.part_name : ""}</td><td>{r.ledger_name || "—"}</td>
            <td><span className="bkt-tag out">{r.from_bucket}</span></td><td><span className="bkt-tag in">{r.to_bucket}</span></td>
            <td className="num"><b>{money(r.qty)}</b></td><td>{r.note || "—"}</td></tr>)}</tbody>
          <tfoot><tr><td colSpan={7} style={{ textAlign: "right" }}>Total Qty Moved</td><td className="num"><b>{money(totQty)}</b></td><td></td></tr></tfoot>
        </table>}
    </div></div>
  </Wrap>);
}

export function OpeningStock({ user }) {
  const BK = ["RC","RCJW","CC","MG","PR","MR","JOBOUT"];
  const BLABEL = { RC: "RC", RCJW: "RC@JW", CC: "CC", MG: "MG", PR: "PR", MR: "MR", JOBOUT: "Sent Out" };
  const [grid, setGrid] = useState([]); const [vals, setVals] = useState({}); const [msg, setMsg] = useState(null); const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState(""); const [onlyFilled, setOnlyFilled] = useState(false); const [saving, setSaving] = useState(false);
  async function load() { setLoading(true); const { data } = await supabase.rpc("opening_grid"); setGrid(data || []); const seed = {}; (data || []).forEach(r => seed[`${r.part_id}:${r.bucket}`] = String(r.qty)); setVals(seed); setLoading(false); }
  useEffect(() => { load(); }, []);
  const key = (pid, b) => `${pid}:${b}`;
  const parts = []; const seen = {};
  grid.forEach(r => { if (!seen[r.part_id]) { seen[r.part_id] = { part_id: r.part_id, part_code: r.part_code, part_name: r.part_name }; parts.push(seen[r.part_id]); } });
  async function save() {
    setSaving(true);
    const rows = []; parts.forEach(p => BK.forEach(b => rows.push({ part_id: p.part_id, bucket: b, qty: +vals[key(p.part_id, b)] || 0 })));
    const { data, error } = await supabase.rpc("admin_save_opening", { p_rows: rows }); setSaving(false);
    if (error) return setMsg({ t: "err", m: error.message }); setMsg({ t: "ok", m: `Opening stock saved — ${data} ${data === 1 ? "balance" : "balances"} recorded.` });
  }
  const partHasValue = p => BK.some(b => +vals[key(p.part_id, b)] > 0);
  const shown = parts.filter(p => (!filter || `${p.part_code} ${p.part_name}`.toLowerCase().includes(filter.toLowerCase())) && (!onlyFilled || partHasValue(p)));
  return (<div className="dsx"><Msg msg={msg} />
    <div className="dsx-head">
      <div><h1>Opening Stock</h1><div className="sub">Set the starting balance for each part across every bucket. Blank counts as zero.</div></div>
      <div className="dsx-head-actions"><button className="dsx-btn primary" onClick={save} disabled={saving}>{saving ? "Saving…" : "Save opening stock"}</button></div>
    </div>
    <div className="dsx-card">
      <div className="dsx-card-h">
        <h2>Balances <span className="sub" style={{ marginLeft: 8 }}>{shown.length} of {parts.length} parts</span></h2>
        <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
          <label className="dsx-check"><input type="checkbox" checked={onlyFilled} onChange={e => setOnlyFilled(e.target.checked)} />Only parts with entries</label>
          <input className="dsx-input" style={{ width: 220, height: 36 }} placeholder="Search part…" value={filter} onChange={e => setFilter(e.target.value)} />
        </div>
      </div>
      <div className="dsx-card-b flush">
        {loading ? <div className="dsx-empty">Loading…</div> : shown.length === 0 ? <div className="dsx-empty"><div className="big">No parts match</div>Try clearing the search or filter.</div>
          : <div className="dsx-table-wrap" style={{ maxHeight: "62vh", overflowY: "auto" }}>
            <table className="dsx-matrix"><thead><tr><th className="stick">Part</th>{BK.map(b => <th key={b}>{BLABEL[b]}</th>)}</tr></thead>
              <tbody>{shown.map(p => <tr key={p.part_id}>
                <td className="stick"><span className="dsx-strong">{p.part_code}</span> <span className="dsx-muted">{p.part_name}</span></td>
                {BK.map(b => <td key={b}><input className="dsx-matrix-in" type="number" placeholder="0" value={vals[key(p.part_id, b)] ?? ""} onChange={e => setVals(s => ({ ...s, [key(p.part_id, b)]: e.target.value }))} /></td>)}</tr>)}</tbody></table>
          </div>}
      </div>
    </div>
  </div>);
}
